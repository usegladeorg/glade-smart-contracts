// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// Custom errors used throughout Glade, declared at file scope so that every
// contract importing this file reverts with an identical selector for an
// identical failure. Clients can therefore decode a revert without first
// working out which module raised it. Compared with revert strings, custom
// errors also cost less both in bytecode and at runtime.

/* ----- General ----- */
error ZeroAddress();
error ProtocolPaused();
error Unauthorized();
error UnauthorizedComplianceAuthority();

/* ----- Account registry and handles ----- */
error InvalidHandleLength();
error InvalidHandleCharacters();
error HandleAlreadyTaken();
error ProfileAlreadyExists();
error ProfileNotFound();

/* ----- Agents ----- */
error InvalidLabelLength();
error AgentNotActive();
error AgentAlreadyRevoked();
error UnauthorizedAgentOwner();
error UnauthorizedAgentSigner();

/* ----- Agent spending policies ----- */
error InvalidSpendAmount();
error PerTxLimitExceedsDailyLimit();
error PerTransactionLimitExceeded();
error DailyLimitExceeded();
error RecipientNotAllowed();
error TooManyAllowedRecipients();
error RecipientAlreadyAllowed();
error RecipientNotOnAllowlist();
error InvalidHitlThreshold();
error AmountExceedsHitlThreshold();
error AmountWithinHitlThreshold();
error TierRequiresApproval();
error InsufficientVaultBalance();

/* ----- Human approvals ----- */
error PendingApprovalNotFound();

/* ----- Payment requests ----- */
error RequestNotOpen();
error RequestExpired();
error RequestAmountMismatch();
error RequestCommitmentMismatch();
error MissingCommitment();
error InvalidExpiry();
error InvalidToken();
error SelfPayment();

/* ----- Disclosure log ----- */
error InvalidTxReferenceLength();

/* ----- Confidential token ----- */
error AccountNotRegistered();
error AccountAlreadyRegistered();
error InvalidPublicKey();
error ProofRejected();
error ExceedsWrappedSupply();

/* ----- Fee schedule ----- */
error InvalidFeeConfig();
