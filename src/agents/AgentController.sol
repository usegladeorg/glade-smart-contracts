// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "../interfaces/IERC20.sol";
import {IProtocolAuthority} from "../interfaces/IProtocolAuthority.sol";
import {IAccountRegistry} from "../interfaces/IAccountRegistry.sol";
import {IFeeSchedule} from "../payments/IFeeSchedule.sol";
import {SafeTransferLib} from "../utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "../utils/ReentrancyGuard.sol";
import "../utils/ProtocolErrors.sol";

/// @title AgentController
/// @notice Spending accounts for AI agents on Glade. An agent gets a vault it
///         can pay from directly, and its owner gets limits that this contract
///         enforces on-chain instead of trusting an off-chain service to.
///
/// @dev Security here comes from keeping the agent's key low in privilege, so
///      that a leaked key is a contained problem. The running system holds
///      `agentSigner`, and that key is limited to spending from its vault, in
///      the single token set at creation, within the owner's policy. Withdrawing,
///      rotating its own key, and raising its own limits are all out of reach.
///      Since the agent's key never custodies the funds directly, the response to
///      a leak is to pause or revoke the agent, not to drain the vault first.
///
///      There is no per-agent vault contract. The ERC-20 sits pooled in this
///      contract and `vaultBalance` records how much of it belongs to each
///      agent, so isolation between agents follows from the accounting itself
///      instead of from an access check.
///
///      x402 support is built in. Whether a spend settles directly or through
///      approval, the `invoiceId` taken from the HTTP 402 challenge is emitted
///      with the payment, giving an operator's webhook a key to reconcile on.
contract AgentController is ReentrancyGuard {
    using SafeTransferLib for IERC20;

    /// @notice Raised if a key rotation targets the signer already in place.
    error SameSigner();

    /// @notice Raised if a status change would leave the agent's status unchanged.
    error SameAgentStatus();

    /// @notice Raised if a rename supplies the agent's current label.
    error SameLabel();

    /// @notice Raised if a tier change supplies the agent's current tier.
    error SameAutonomyTier();

    /// @notice The degree of independence an agent has before a human must approve.
    enum AutonomyTier {
        /// Direct settlement is disabled; each spend goes to the approval queue.
        Supervised,
        /// Direct settlement up to the approval threshold, queueing beyond it.
        SemiAutonomous,
        /// Direct settlement for any spend the policy allows.
        FullyAutonomous
    }

    enum AgentStatus {
        Active,
        Paused,
        Revoked
    }

    /// @notice The outcome a spend would get if submitted in the current state.
    enum SpendRoute {
        /// Settlement would happen immediately through {payInvoice}.
        Settles,
        /// {queueInvoice} would record it for an owner decision.
        Queues,
        /// Under current conditions both paths would reject it.
        Refused
    }

    struct Agent {
        address ownerProfile; // owning account address
        address agentSigner; // key used by the live agent to submit spends
        string label; // human-friendly name, e.g. "coding-assistant"
        AutonomyTier autonomyTier;
        AgentStatus status;
        uint64 createdAt;
        bool exists;
    }

    /// @notice Spending constraints for a single agent and its single token.
    struct SpendPolicy {
        address token; // sole asset the agent can spend
        uint256 perTxLimit; // cap per individual settled spend
        uint256 dailyLimit; // cap for the 24-hour window
        uint256 hitlThreshold; // amounts above this require human approval
        uint64 windowStart; // opening time of the active window
        uint256 windowSpent; // total settled within the active window
        bool allowlistEnabled; // if true, payees are restricted to allowedRecipients
        address[] allowedRecipients;
        uint64 updatedAt;
    }

    /// @notice A queued spend waiting on the owner. No tokens have moved yet.
    struct PendingApproval {
        uint256 agentId;
        address ownerProfile;
        address recipient;
        address token;
        uint256 amount;
        bytes32 invoiceId; // x402 invoice reference; zero when not an x402 payment
        bytes32 memoHash; // commitment to the encrypted memo the approver reads
        uint64 createdAt;
        bool exists;
    }

    uint256 internal constant MAX_LABEL_LEN = 40;
    uint256 internal constant MAX_ALLOWED_RECIPIENTS = 10;
    uint256 internal constant WINDOW = 1 days;

    /// @notice Most unresolved queued spends an agent may have at once. A
    ///         leaked signer key cannot pay out past the policy, but it could
    ///         otherwise flood the owner's approval queue and grow
    ///         {openPendingIds} without bound.
    uint256 public constant MAX_OPEN_PENDING = 25;

    IProtocolAuthority public immutable protocol;
    IAccountRegistry public immutable registry;

    uint256 public agentCount;

    mapping(uint256 => Agent) internal _agents;
    mapping(uint256 => SpendPolicy) internal _policies;
    mapping(uint256 => uint256) public vaultBalance; // agentId => share of pooled tokens
    mapping(uint256 => uint256) public pendingCount; // agentId => id the next queued spend receives
    mapping(uint256 => uint256) public openPendingCount; // agentId => queued spends still unresolved
    mapping(uint256 => mapping(uint256 => PendingApproval)) internal _pending;

    /// @notice For each owner, the ids of its agents in creation order. Lets a
    ///         wallet enumerate agents directly instead of indexing events.
    ///         Revocation does not remove an entry; check the agent's status.
    mapping(address => uint256[]) internal _agentsByOwner;

    event AgentCreated(
        uint256 indexed agentId,
        address indexed ownerProfile,
        address indexed agentSigner,
        string label,
        AutonomyTier autonomyTier,
        address token,
        uint256 timestamp
    );
    event SpendPolicyUpdated(
        uint256 indexed agentId,
        uint256 perTxLimit,
        uint256 dailyLimit,
        uint256 hitlThreshold,
        bool allowlistEnabled,
        address[] allowedRecipients,
        uint256 timestamp
    );
    event AgentStatusChanged(uint256 indexed agentId, AgentStatus status, uint256 timestamp);
    event AllowedRecipientAdded(
        uint256 indexed agentId, address indexed recipient, uint256 timestamp
    );
    event AllowedRecipientRemoved(
        uint256 indexed agentId, address indexed recipient, uint256 timestamp
    );
    event AutonomyTierChanged(
        uint256 indexed agentId, AutonomyTier previousTier, AutonomyTier newTier, uint256 timestamp
    );
    event AgentRenamed(
        uint256 indexed agentId, string previousLabel, string newLabel, uint256 timestamp
    );
    event AgentSignerRotated(
        uint256 indexed agentId,
        address indexed previousSigner,
        address indexed newSigner,
        uint256 timestamp
    );
    event AgentFunded(
        uint256 indexed agentId, address indexed funder, uint256 amount, uint256 timestamp
    );
    event AgentDefunded(
        uint256 indexed agentId, address indexed owner, uint256 amount, uint256 timestamp
    );
    event AgentPaymentExecuted(
        uint256 indexed agentId,
        address indexed recipient,
        address token,
        uint256 amount,
        bytes32 invoiceId,
        uint256 windowSpent,
        uint256 timestamp
    );
    event ApprovalRequired(
        uint256 indexed agentId,
        uint256 indexed pendingId,
        address indexed recipient,
        address token,
        uint256 amount,
        bytes32 invoiceId,
        uint256 timestamp
    );
    event PendingPaymentApproved(
        uint256 indexed agentId,
        uint256 indexed pendingId,
        address indexed recipient,
        uint256 amount,
        uint256 timestamp
    );
    event PendingPaymentRejected(
        uint256 indexed agentId, uint256 indexed pendingId, uint256 timestamp
    );
    event PendingPaymentWithdrawn(
        uint256 indexed agentId, uint256 indexed pendingId, uint256 timestamp
    );
    event ProtocolFeeCharged(
        uint256 indexed agentId, address indexed treasury, uint256 fee, uint256 timestamp
    );

    constructor(IProtocolAuthority protocol_, IAccountRegistry registry_) {
        if (address(protocol_) == address(0) || address(registry_) == address(0)) {
            revert ZeroAddress();
        }
        protocol = protocol_;
        registry = registry_;
    }

    /* ------------------------------ Modifiers ------------------------------ */

    modifier whenNotPaused() {
        if (protocol.paused()) revert ProtocolPaused();
        _;
    }

    modifier onlyAgentOwner(uint256 agentId) {
        if (_agents[agentId].ownerProfile != msg.sender) revert UnauthorizedAgentOwner();
        _;
    }

    modifier onlyAgentSigner(uint256 agentId) {
        if (_agents[agentId].agentSigner != msg.sender) revert UnauthorizedAgentSigner();
        _;
    }

    /* ---------------------------- Agent lifecycle --------------------------- */

    /// @notice Creates a new agent owned by the caller and installs its initial
    ///         spend policy. Its vault is simply the balance kept under the
    ///         returned `agentId`, which {fundAgent} tops up.
    /// @param agentSigner Address of the key the agent will use for spends. It is
    ///        only stored; this transaction is not signed by it.
    /// @param label Display name between 1 and 40 characters long.
    /// @param token The one ERC-20 this agent will be allowed to spend.
    function createAgent(
        address agentSigner,
        string calldata label,
        AutonomyTier autonomyTier,
        address token,
        uint256 perTxLimit,
        uint256 dailyLimit,
        uint256 hitlThreshold,
        address[] calldata allowedRecipients,
        bool allowlistEnabled
    ) external returns (uint256 agentId) {
        if (!registry.isRegistered(msg.sender)) revert ProfileNotFound();
        if (agentSigner == address(0) || token == address(0)) revert ZeroAddress();
        // Mirrors the check RequestLedger makes on request tokens. A codeless
        // address can never transfer anything in, so the vault would stay empty.
        if (token.code.length == 0) revert InvalidToken();

        uint256 len = bytes(label).length;
        if (len == 0 || len > MAX_LABEL_LEN) revert InvalidLabelLength();
        _validateLimits(perTxLimit, dailyLimit, hitlThreshold, allowedRecipients.length);
        _validateRecipients(allowedRecipients);

        agentId = ++agentCount;

        _agents[agentId] = Agent({
            ownerProfile: msg.sender,
            agentSigner: agentSigner,
            label: label,
            autonomyTier: autonomyTier,
            status: AgentStatus.Active,
            createdAt: uint64(block.timestamp),
            exists: true
        });

        SpendPolicy storage p = _policies[agentId];
        p.token = token;
        p.perTxLimit = perTxLimit;
        p.dailyLimit = dailyLimit;
        p.hitlThreshold = hitlThreshold;
        p.windowStart = uint64(block.timestamp);
        p.allowlistEnabled = allowlistEnabled;
        p.allowedRecipients = allowedRecipients;
        p.updatedAt = uint64(block.timestamp);
        _agentsByOwner[msg.sender].push(agentId);

        emit AgentCreated(
            agentId, msg.sender, agentSigner, label, autonomyTier, token, block.timestamp
        );
        emit SpendPolicyUpdated(
            agentId,
            perTxLimit,
            dailyLimit,
            hitlThreshold,
            allowlistEnabled,
            allowedRecipients,
            block.timestamp
        );
    }

    /// @notice Replaces the agent's limits, approval threshold and allowlist in
    ///         full. Only the owner may call this; the agent itself cannot
    ///         loosen its own constraints. Once an agent is revoked its policy
    ///         (like its signer) can no longer change, preserving the final state.
    function updateSpendPolicy(
        uint256 agentId,
        uint256 perTxLimit,
        uint256 dailyLimit,
        uint256 hitlThreshold,
        bool allowlistEnabled,
        address[] calldata allowedRecipients
    ) external onlyAgentOwner(agentId) {
        if (_agents[agentId].status == AgentStatus.Revoked) {
            revert AgentAlreadyRevoked();
        }
        _validateLimits(perTxLimit, dailyLimit, hitlThreshold, allowedRecipients.length);
        _validateRecipients(allowedRecipients);

        SpendPolicy storage p = _policies[agentId];
        p.perTxLimit = perTxLimit;
        p.dailyLimit = dailyLimit;
        p.hitlThreshold = hitlThreshold;
        p.allowlistEnabled = allowlistEnabled;
        p.allowedRecipients = allowedRecipients;
        p.updatedAt = uint64(block.timestamp);

        emit SpendPolicyUpdated(
            agentId,
            perTxLimit,
            dailyLimit,
            hitlThreshold,
            allowlistEnabled,
            allowedRecipients,
            block.timestamp
        );
    }

    /// @notice Appends a single address to the allowlist, leaving the other
    ///         policy fields alone. Whether the list is enforced at all depends
    ///         on `allowlistEnabled`, set through {updateSpendPolicy}.
    function addAllowedRecipient(uint256 agentId, address recipient)
        external
        onlyAgentOwner(agentId)
    {
        if (recipient == address(0)) revert ZeroAddress();
        if (_agents[agentId].status == AgentStatus.Revoked) revert AgentAlreadyRevoked();
        SpendPolicy storage p = _policies[agentId];
        address[] storage list = p.allowedRecipients;
        if (list.length >= MAX_ALLOWED_RECIPIENTS) revert TooManyAllowedRecipients();
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == recipient) revert RecipientAlreadyAllowed();
        }
        list.push(recipient);
        p.updatedAt = uint64(block.timestamp);
        emit AllowedRecipientAdded(agentId, recipient, block.timestamp);
    }

    /// @notice Removes a single address from the allowlist using swap-and-pop,
    ///         so the remaining entries may be reordered.
    function removeAllowedRecipient(uint256 agentId, address recipient)
        external
        onlyAgentOwner(agentId)
    {
        if (_agents[agentId].status == AgentStatus.Revoked) revert AgentAlreadyRevoked();
        SpendPolicy storage p = _policies[agentId];
        address[] storage list = p.allowedRecipients;
        uint256 n = list.length;
        for (uint256 i; i < n; ++i) {
            if (list[i] == recipient) {
                list[i] = list[n - 1];
                list.pop();
                p.updatedAt = uint64(block.timestamp);
                emit AllowedRecipientRemoved(agentId, recipient, block.timestamp);
                return;
            }
        }
        revert RecipientNotOnAllowlist();
    }

    /// @notice Updates the agent's display name. Nothing else is affected (signer,
    ///         vault, policy and past activity stay as they were); this exists so
    ///         owners are not stuck with the name chosen at creation.
    function renameAgent(uint256 agentId, string calldata label) external onlyAgentOwner(agentId) {
        uint256 len = bytes(label).length;
        if (len == 0 || len > MAX_LABEL_LEN) revert InvalidLabelLength();
        Agent storage a = _agents[agentId];
        if (a.status == AgentStatus.Revoked) revert AgentAlreadyRevoked();
        if (keccak256(bytes(a.label)) == keccak256(bytes(label))) revert SameLabel();

        string memory previous = a.label;
        a.label = label;
        emit AgentRenamed(agentId, previous, label, block.timestamp);
    }

    /// @notice Moves the agent to a different autonomy tier. Owners usually
    ///         start an agent on Supervised and promote it once they trust its
    ///         behaviour, or demote it after something looks off, without
    ///         recreating the agent and moving its vault.
    /// @dev Spends already sitting in the queue are left alone. They are
    ///      re-checked against policy when the owner approves them, and the
    ///      tier only governs which path a new spend may take.
    function setAutonomyTier(uint256 agentId, AutonomyTier autonomyTier)
        external
        onlyAgentOwner(agentId)
    {
        Agent storage a = _agents[agentId];
        if (a.status == AgentStatus.Revoked) revert AgentAlreadyRevoked();
        if (a.autonomyTier == autonomyTier) revert SameAutonomyTier();

        AutonomyTier previous = a.autonomyTier;
        a.autonomyTier = autonomyTier;
        emit AutonomyTierChanged(agentId, previous, autonomyTier, block.timestamp);
    }

    /// @notice Toggles an agent between Active and Paused without touching its
    ///         vault or policy. Intended for maintenance windows or a suspected
    ///         key compromise. Permanent shutdown goes through {revokeAgent}.
    function setAgentStatus(uint256 agentId, AgentStatus status) external onlyAgentOwner(agentId) {
        if (status == AgentStatus.Revoked) revert AgentAlreadyRevoked();
        Agent storage a = _agents[agentId];
        if (a.status == AgentStatus.Revoked) revert AgentAlreadyRevoked();
        if (a.status == status) revert SameAgentStatus();

        a.status = status;
        emit AgentStatusChanged(agentId, status, block.timestamp);
    }

    /// @notice Points the agent at a new signing key. Vault, policy and spend
    ///         history carry over unchanged.
    /// @dev Handles a compromised key without recreating the agent: the owner
    ///      can pause, install a fresh signer, then reactivate. Only the owner
    ///      may rotate; the agent's own key has no say, and revoked agents
    ///      cannot be rotated back into use.
    function rotateAgentSigner(uint256 agentId, address newSigner)
        external
        onlyAgentOwner(agentId)
    {
        if (newSigner == address(0)) revert ZeroAddress();
        Agent storage a = _agents[agentId];
        if (a.status == AgentStatus.Revoked) revert AgentAlreadyRevoked();
        if (a.agentSigner == newSigner) revert SameSigner();

        address previous = a.agentSigner;
        a.agentSigner = newSigner;
        emit AgentSignerRotated(agentId, previous, newSigner, block.timestamp);
    }

    /// @notice Permanently shuts the agent down and sends its remaining vault
    ///         balance back to the owner atomically. Revocation is irreversible,
    ///         which guarantees the retired key is never accepted again.
    function revokeAgent(uint256 agentId) external nonReentrant onlyAgentOwner(agentId) {
        Agent storage a = _agents[agentId];
        if (a.status == AgentStatus.Revoked) revert AgentAlreadyRevoked();

        a.status = AgentStatus.Revoked;

        uint256 remaining = vaultBalance[agentId];
        if (remaining > 0) {
            vaultBalance[agentId] = 0;
            IERC20(_policies[agentId].token).safeTransfer(msg.sender, remaining);
        }

        emit AgentStatusChanged(agentId, AgentStatus.Revoked, block.timestamp);
    }

    /* -------------------------------- Vault -------------------------------- */

    /// @notice Deposits the agent's token into its vault. Any address can fund,
    ///         though usually the owner does. Agents cannot credit themselves,
    ///         so every deposit is an explicit choice by whoever sends it.
    function fundAgent(uint256 agentId, uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidSpendAmount();
        Agent storage a = _agents[agentId];
        if (!a.exists) revert AgentNotActive();
        if (a.status == AgentStatus.Revoked) revert AgentAlreadyRevoked();

        // Measure the balance delta and credit that, not `amount`. Tokens that
        // take a transfer fee would otherwise inflate the recorded vault.
        IERC20 token = IERC20(_policies[agentId].token);
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - before;
        if (received == 0) revert InvalidSpendAmount();

        vaultBalance[agentId] += received;
        emit AgentFunded(agentId, msg.sender, received, block.timestamp);
    }

    /// @notice Returns some of the vault to the owner without stopping the
    ///         agent. It gives owners a way to fix overfunding short of the
    ///         irreversible {revokeAgent}.
    /// @dev Neither the protocol pause nor the agent's status blocks this,
    ///      matching {revokeAgent}: owners must be able to recover funds during
    ///      an incident, which is exactly when pauses are in effect. Access is
    ///      limited to the owning account, never the agent signer.
    function withdrawFromAgent(uint256 agentId, uint256 amount)
        external
        nonReentrant
        onlyAgentOwner(agentId)
    {
        if (amount == 0) revert InvalidSpendAmount();
        if (amount > vaultBalance[agentId]) revert InsufficientVaultBalance();

        vaultBalance[agentId] -= amount;
        IERC20(_policies[agentId].token).safeTransfer(msg.sender, amount);

        emit AgentDefunded(agentId, msg.sender, amount, block.timestamp);
    }

    /* ------------------------------- Spending ------------------------------ */

    /// @notice Immediate settlement path, called with the agent's signing key
    ///         and bounded by its autonomy tier.
    /// @dev Supervised agents cannot use this at all and must go through
    ///      {queueInvoice}. SemiAutonomous agents may settle amounts up to
    ///      `hitlThreshold`. FullyAutonomous agents may settle anything within
    ///      policy. Every tier remains subject to the per-transaction limit,
    ///      the daily limit and the allowlist; a higher tier only enlarges the
    ///      range that skips approval, it does not relax those limits.
    /// @param invoiceId x402 invoice reference carried into the payment event;
    ///        zero for a transfer with no invoice.
    function payInvoice(uint256 agentId, address recipient, uint256 amount, bytes32 invoiceId)
        external
        nonReentrant
        whenNotPaused
        onlyAgentSigner(agentId)
    {
        if (amount == 0) revert InvalidSpendAmount();
        if (recipient == address(0)) revert ZeroAddress();
        Agent storage a = _agents[agentId];
        if (a.status != AgentStatus.Active) revert AgentNotActive();
        if (a.autonomyTier == AutonomyTier.Supervised) revert TierRequiresApproval();

        SpendPolicy storage p = _policies[agentId];
        if (amount > p.perTxLimit) revert PerTransactionLimitExceeded();
        if (a.autonomyTier == AutonomyTier.SemiAutonomous && amount > p.hitlThreshold) {
            revert AmountExceedsHitlThreshold();
        }
        _checkAllowlist(p, recipient);

        _rollWindow(p);
        uint256 projected = p.windowSpent + amount;
        if (projected > p.dailyLimit) revert DailyLimitExceeded();

        (uint256 fee, address treasury) = _quoteFee(agentId, amount);
        if (amount + fee > vaultBalance[agentId]) revert InsufficientVaultBalance();

        // Effects first: bookkeeping is finalised ahead of any external transfer.
        p.windowSpent = projected;
        p.updatedAt = uint64(block.timestamp);
        vaultBalance[agentId] -= amount + fee;

        IERC20(p.token).safeTransfer(recipient, amount);
        if (fee > 0) {
            IERC20(p.token).safeTransfer(treasury, fee);
            emit ProtocolFeeCharged(agentId, treasury, fee, block.timestamp);
        }

        emit AgentPaymentExecuted(
            agentId, recipient, p.token, amount, invoiceId, projected, block.timestamp
        );
    }

    /// @notice Records a spend for the owner to approve or reject. Funds stay
    ///         in the vault until {approvePending} executes it.
    /// @dev Supervised agents queue every spend, and FullyAutonomous agents can
    ///      choose to queue anything they want reviewed. SemiAutonomous agents
    ///      may only queue amounts above `hitlThreshold`, because anything at or
    ///      under it belongs on {payInvoice}. The allowlist and per-transaction
    ///      limit are enforced at queue time to keep doomed requests out of the
    ///      queue. The daily limit is checked later, at approval, because the
    ///      remaining allowance can change between queueing and review.
    function queueInvoice(
        uint256 agentId,
        address recipient,
        uint256 amount,
        bytes32 invoiceId,
        bytes32 memoHash
    ) external whenNotPaused onlyAgentSigner(agentId) returns (uint256 pendingId) {
        if (amount == 0) revert InvalidSpendAmount();
        if (recipient == address(0)) revert ZeroAddress();
        Agent storage a = _agents[agentId];
        if (a.status != AgentStatus.Active) revert AgentNotActive();

        SpendPolicy storage p = _policies[agentId];
        if (amount > p.perTxLimit) revert PerTransactionLimitExceeded();
        if (a.autonomyTier == AutonomyTier.SemiAutonomous && amount <= p.hitlThreshold) {
            revert AmountWithinHitlThreshold();
        }
        _checkAllowlist(p, recipient);
        if (openPendingCount[agentId] >= MAX_OPEN_PENDING) revert TooManyPendingApprovals();

        pendingId = pendingCount[agentId]++;
        ++openPendingCount[agentId];
        _pending[agentId][pendingId] = PendingApproval({
            agentId: agentId,
            ownerProfile: a.ownerProfile,
            recipient: recipient,
            token: p.token,
            amount: amount,
            invoiceId: invoiceId,
            memoHash: memoHash,
            createdAt: uint64(block.timestamp),
            exists: true
        });

        emit ApprovalRequired(
            agentId, pendingId, recipient, p.token, amount, invoiceId, block.timestamp
        );
    }

    /// @notice Owner approval that executes a queued spend. All policy checks
    ///         run again at this point, since the allowlist, per-transaction
    ///         limit or daily usage may differ from when it was queued.
    function approvePending(uint256 agentId, uint256 pendingId)
        external
        nonReentrant
        whenNotPaused
        onlyAgentOwner(agentId)
    {
        if (_agents[agentId].status != AgentStatus.Active) revert AgentNotActive();

        PendingApproval storage pa = _pending[agentId][pendingId];
        if (!pa.exists) revert PendingApprovalNotFound();

        uint256 amount = pa.amount;
        address recipient = pa.recipient;
        bytes32 invoiceId = pa.invoiceId;

        SpendPolicy storage p = _policies[agentId];
        _checkAllowlist(p, recipient);
        if (amount > p.perTxLimit) revert PerTransactionLimitExceeded();

        _rollWindow(p);
        uint256 projected = p.windowSpent + amount;
        if (projected > p.dailyLimit) revert DailyLimitExceeded();

        (uint256 fee, address treasury) = _quoteFee(agentId, amount);
        if (amount + fee > vaultBalance[agentId]) revert InsufficientVaultBalance();

        // Effects first: bookkeeping and record removal precede the transfers.
        p.windowSpent = projected;
        p.updatedAt = uint64(block.timestamp);
        vaultBalance[agentId] -= amount + fee;
        delete _pending[agentId][pendingId];
        --openPendingCount[agentId];

        IERC20(p.token).safeTransfer(recipient, amount);
        if (fee > 0) {
            IERC20(p.token).safeTransfer(treasury, fee);
            emit ProtocolFeeCharged(agentId, treasury, fee, block.timestamp);
        }

        emit AgentPaymentExecuted(
            agentId, recipient, p.token, amount, invoiceId, projected, block.timestamp
        );
        emit PendingPaymentApproved(agentId, pendingId, recipient, amount, block.timestamp);
    }

    /// @notice Owner declines a queued spend. The vault was never debited, so
    ///         deleting the pending record is all that happens.
    function rejectPending(uint256 agentId, uint256 pendingId) external onlyAgentOwner(agentId) {
        if (!_pending[agentId][pendingId].exists) revert PendingApprovalNotFound();
        delete _pending[agentId][pendingId];
        --openPendingCount[agentId];
        emit PendingPaymentRejected(agentId, pendingId, block.timestamp);
    }

    /// @notice Lets the agent cancel one of its own queued spends, e.g. after
    ///         the underlying x402 challenge expires. The record is deleted and
    ///         no funds are involved. Owner rejections use {rejectPending}
    ///         instead, and each emits its own event so history shows which
    ///         party cancelled.
    function withdrawPending(uint256 agentId, uint256 pendingId) external onlyAgentSigner(agentId) {
        if (!_pending[agentId][pendingId].exists) revert PendingApprovalNotFound();
        delete _pending[agentId][pendingId];
        --openPendingCount[agentId];
        emit PendingPaymentWithdrawn(agentId, pendingId, block.timestamp);
    }

    /* -------------------------------- Views -------------------------------- */

    function getAgent(uint256 agentId) external view returns (Agent memory) {
        return _agents[agentId];
    }

    function getPolicy(uint256 agentId) external view returns (SpendPolicy memory) {
        return _policies[agentId];
    }

    function getPending(uint256 agentId, uint256 pendingId)
        external
        view
        returns (PendingApproval memory)
    {
        return _pending[agentId][pendingId];
    }

    /// @notice Ids of an agent's unresolved queued spends, in ascending order.
    ///         Because ids are sequential and resolved entries get deleted, this
    ///         saves an approval UI from probing every id ever assigned.
    /// @dev The array is sized from {openPendingCount}, so only one pass over
    ///      the issued ids is needed, and it stops as soon as every open entry
    ///      has been found.
    function openPendingIds(uint256 agentId) external view returns (uint256[] memory ids) {
        uint256 open = openPendingCount[agentId];
        ids = new uint256[](open);
        uint256 k;
        uint256 issued = pendingCount[agentId];
        for (uint256 i; i < issued && k < open; ++i) {
            if (_pending[agentId][i].exists) ids[k++] = i;
        }
    }

    /// @notice Total agents ever created by `owner`, counting revoked ones.
    function agentCountOf(address owner) external view returns (uint256) {
        return _agentsByOwner[owner].length;
    }

    /// @notice All agent ids created by `owner`, in creation order. Look each
    ///         one up with {getAgent} for full details.
    function agentIdsOf(address owner) external view returns (uint256[] memory) {
        return _agentsByOwner[owner];
    }

    /// @notice Paginated version of {agentIdsOf}: up to `limit` ids starting at
    ///         index `offset`, in creation order. Operators running many agents
    ///         can page through them the same way wallets page payment requests.
    function agentIdsOf(address owner, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory page)
    {
        uint256[] storage all = _agentsByOwner[owner];
        uint256 total = all.length;
        if (offset >= total) return new uint256[](0);

        // Compare `limit` with the remaining count before adding, so passing
        // type(uint256).max returns the rest of the list instead of overflowing.
        uint256 end = limit > total - offset ? total : offset + limit;

        page = new uint256[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            page[i - offset] = all[i];
        }
    }

    /// @notice Predicts whether a spend would settle, queue, or be refused at
    ///         this moment. It replicates the checks of {payInvoice} and
    ///         {queueInvoice}, letting an agent avoid a doomed transaction and
    ///         letting a frontend show the right action.
    /// @dev Daily usage and vault balance reflect the current window. A queued
    ///      spend is checked again on approval, so a `Queues` result only means
    ///      {queueInvoice} would accept it, not that it will later settle.
    function routeFor(uint256 agentId, address recipient, uint256 amount)
        external
        view
        returns (SpendRoute)
    {
        Agent storage a = _agents[agentId];
        if (!a.exists || a.status != AgentStatus.Active) return SpendRoute.Refused;
        if (amount == 0 || recipient == address(0)) return SpendRoute.Refused;
        if (protocol.paused()) return SpendRoute.Refused;

        SpendPolicy storage p = _policies[agentId];
        if (amount > p.perTxLimit) return SpendRoute.Refused;
        if (!_isAllowed(p, recipient)) return SpendRoute.Refused;

        // Spends that need human sign-off under this tier are routed to the queue.
        if (a.autonomyTier == AutonomyTier.Supervised) return SpendRoute.Queues;
        if (a.autonomyTier == AutonomyTier.SemiAutonomous && amount > p.hitlThreshold) {
            return SpendRoute.Queues;
        }

        // Otherwise it is a direct-settle candidate, subject to daily headroom and vault funds.
        uint256 spent = block.timestamp - p.windowStart >= WINDOW ? 0 : p.windowSpent;
        if (spent + amount > p.dailyLimit) return SpendRoute.Refused;
        (uint256 fee,) = _quoteFee(agentId, amount);
        if (amount + fee > vaultBalance[agentId]) return SpendRoute.Refused;

        return SpendRoute.Settles;
    }

    /// @notice Timestamp at which the current 24-hour spending window expires.
    ///         If it has already expired, the current block timestamp is
    ///         returned, since the next spend will start a new window. Combine
    ///         with {remainingDailyAllowance} for a "X left, resets in Y" display.
    function windowResetsAt(uint256 agentId) external view returns (uint256) {
        uint256 resetAt = uint256(_policies[agentId].windowStart) + WINDOW;
        return resetAt > block.timestamp ? resetAt : block.timestamp;
    }

    /// @notice Remaining spendable amount under the daily limit, treating an
    ///         expired window as fully reset.
    function remainingDailyAllowance(uint256 agentId) external view returns (uint256) {
        SpendPolicy storage p = _policies[agentId];
        uint256 spent = block.timestamp - p.windowStart >= WINDOW ? 0 : p.windowSpent;
        return spent >= p.dailyLimit ? 0 : p.dailyLimit - spent;
    }

    /* ------------------------------- Internals ------------------------------ */

    /// @dev Computes the protocol fee for a spend. When fee routing is disabled
    ///      it returns zero values, keeping agents that predate fees unaffected.
    ///      The fee is charged in addition to the spend, drawn from the same
    ///      vault, and excluded from policy accounting, because the limits cap
    ///      the agent's payments rather than the protocol's charge for them.
    function _quoteFee(uint256 agentId, uint256 amount)
        internal
        view
        returns (uint256 fee, address treasury)
    {
        address schedule = protocol.feeSchedule();
        treasury = protocol.treasury();
        if (schedule == address(0) || treasury == address(0)) return (0, address(0));
        (fee,) = IFeeSchedule(schedule).quoteFee(_agents[agentId].ownerProfile, amount);
    }

    function _validateLimits(
        uint256 perTxLimit,
        uint256 dailyLimit,
        uint256 hitlThreshold,
        uint256 allowlistLen
    ) internal pure {
        if (hitlThreshold == 0) revert InvalidHitlThreshold();
        if (perTxLimit == 0 || dailyLimit == 0) revert InvalidSpendAmount();
        if (perTxLimit > dailyLimit) revert PerTxLimitExceedsDailyLimit();
        if (allowlistLen > MAX_ALLOWED_RECIPIENTS) revert TooManyAllowedRecipients();
    }

    /// @dev Bulk counterpart to the per-entry checks in {addAllowedRecipient}:
    ///      rejects the zero address and any repeated entry. The O(n^2) scan is
    ///      acceptable because the length is bounded by MAX_ALLOWED_RECIPIENTS.
    function _validateRecipients(address[] calldata list) internal pure {
        uint256 n = list.length;
        for (uint256 i; i < n; ++i) {
            if (list[i] == address(0)) revert ZeroAddress();
            for (uint256 j = i + 1; j < n; ++j) {
                if (list[i] == list[j]) revert RecipientAlreadyAllowed();
            }
        }
    }

    function _checkAllowlist(SpendPolicy storage p, address recipient) internal view {
        if (!_isAllowed(p, recipient)) revert RecipientNotAllowed();
    }

    function _isAllowed(SpendPolicy storage p, address recipient) internal view returns (bool) {
        if (!p.allowlistEnabled) return true;
        address[] storage list = p.allowedRecipients;
        uint256 n = list.length;
        for (uint256 i; i < n; ++i) {
            if (list[i] == recipient) return true;
        }
        return false;
    }

    /// @dev Lazily starts a new window when a spend lands 24 hours or more after
    ///      the current one began, so no separate reset transaction is needed.
    function _rollWindow(SpendPolicy storage p) internal {
        if (block.timestamp - p.windowStart >= WINDOW) {
            p.windowStart = uint64(block.timestamp);
            p.windowSpent = 0;
        }
    }
}
