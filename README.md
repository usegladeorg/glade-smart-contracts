<p align="center">
  <img src="https://useglade.org/images/logo-bg.png" alt="Glade" width="88" height="88">
</p>

<h1 align="center">Glade protocol</h1>

<p align="center">
  <a href="https://useglade.org">useglade.org</a> &nbsp;·&nbsp;
  <a href="https://docs.useglade.org">Docs</a> &nbsp;·&nbsp;
  <a href="https://x.com/usegladeorg">@usegladeorg</a>
</p>

These are the smart contracts behind Glade, the private neobank for people and the AI agents working on their behalf. They target Robinhood Chain, an Arbitrum Nitro rollup, and mainnet deployments live on chain ID 4663.

## The short version

Glade keeps the amount of every transfer encrypted while leaving the parties visible. Who paid whom is public on-chain; how much moved is not.

The code splits into two parts. `ConfidentialToken` wraps USDG and stores each balance, and each transfer amount, as an ElGamal ciphertext on the alt_bn128 curve. A verifier contract confirms every transfer is correct without ever seeing the figures. Around that token sits the machinery that turns an encrypted balance into something you can bank with: permanent `.glade` names, agents whose limits are enforced by the chain itself, a review queue for payments a person should sign off on, request-to-pay links, and receipts showing a disclosure happened.

### Why not put everything in the token?

Encryption buys privacy and nothing else. A ciphertext can't tell you that `gwen.glade` belongs to a particular wallet, that an agent has spent its daily allowance, that a payment request lapsed unpaid, or that someone answered an auditor's request last March. Pushing those facts into the token would mean extra circuits to prove and extra ways to break. So they live beside it, as ordinary contract state, and the client brings the two together when a payment settles.

## What each contract does

Source is grouped by area under `src/`.

| Area | Contract | What it is for |
|---|---|---|
| `core/` | `ProtocolAuthority` | Admin and compliance roles, the global pause and fee routing. It never takes custody of funds. |
| `core/` | `AccountRegistry` | One record per wallet, unique `.glade` handles, and KYC tiers written by the compliance role. |
| `agents/` | `AgentController` | Everything about agents: their records and vaults, the spend policy the chain enforces, the queue of payments awaiting approval, and key rotation or revocation. |
| `payments/` | `RequestLedger` | Payment requests, including confidential ones where a commitment stands in for the amount. |
| `payments/` | `FeeSchedule` | The only place prices are defined. Any call that moves value asks it for the fee. |
| `privacy/` | `ConfidentialToken` | The encrypted-balance USDG wrapper: register, deposit, transfer, withdraw. |
| `privacy/` | `AltBn128` | BN254 group arithmetic over the `0x06` and `0x07` precompiles, used to combine ciphertexts. |
| `privacy/` | `IConfidentialTransferVerifier` | What a deployed Groth16 verifier must implement. `StubTransferVerifier` is a placeholder for bring-up and accepts everything. |
| `privacy/` | `DisclosureLog` | A timestamped note that a disclosure took place. It names no counterparty and publishes no proof. |

Shared interfaces (`IERC20`, `IProtocolAuthority`, `IAccountRegistry`) sit in `src/interfaces/`, and the helpers (`SafeTransferLib`, `ReentrancyGuard`, the shared error set) sit in `src/utils/`.

## Agent payments

### The agent's key

An agent signs with `agentSigner`, a key held by whatever service operates it. That key can do very little on purpose. It reaches only funds already sitting in a contract-controlled vault, only in the agent's single settlement token, and only within the policy set by its owner. Nothing is ever held under the agent key itself, so a leaked key calls for pausing or revoking the agent rather than a race to move the money first.

Vaults are internal balances inside `AgentController`. `fundAgent` credits whatever amount actually arrived, so a token that skims on transfer can't inflate a vault. No agent can reach another agent's balance.

### Settle now or wait for a person

The `hitlThreshold` value decides which way a payment goes.

- **`payInvoice`** settles on the spot once it passes four checks: the per-transaction cap, the rolling 24-hour window, the recipient allowlist, and the threshold itself. The window clears on its own when a payment lands more than a day after the window opened, so nobody has to reset it.
- **`queueInvoice`** parks a payment above the threshold without moving any money. The allowlist and per-transaction cap apply immediately, so the queue never fills with payments that could not succeed anyway. The daily cap waits until approval on purpose: something that fit when queued may no longer fit when a person gets to it.

The owner then picks one of two calls. `approvePending` re-runs the policy against the current state before paying out. `rejectPending` removes the entry, and because no funds moved, there's nothing to unwind.

Whichever path is taken, the x402 `invoiceId` is carried into the `AgentPaymentExecuted` event so an operator's webhook can match payments to invoices.

### Asking first

Before paying, an agent or interface can call `routeFor(agentId, recipient, amount)`. It runs the same checks as a view and answers `Settles`, `Queues` or `Refused`. `agentIdsOf` lists the agents a wallet owns, in the same style the request ledger and disclosure log use for their own records.

### Owner controls

- `setAgentStatus` pauses or resumes an agent. Its vault and policy are untouched.
- `rotateAgentSigner` installs a new key while keeping the vault, policy and history, which gives a compromised key a way out that doesn't involve tearing the agent down.
- `revokeAgent` is permanent and returns whatever is left in the vault to the owner within the same transaction.

## Confidential transfers

Every account registers an ElGamal public key and keeps one ciphertext balance. From there:

1. **`deposit`** brings the underlying asset in. It adds `amount * G` to the ciphertext's message half and uses no randomness at all. This is the standard Zether funding step, and it leaves the depositor able to decrypt their running balance with their view key.
2. **`confidentialTransfer`** takes two ElGamal deltas (one encrypting `-amount` for the sender, one encrypting `+amount` for the recipient) plus a proof. The verifier checks that both encode the same non-negative amount and that the sender stays solvent. The contract then folds each delta into the right balance with point addition, which is why the amount never appears in calldata or storage.
3. **`withdraw`** unwraps against a proof that the encrypted balance covers the amount. Here the amount is public, since the ERC-20 transfer that follows would expose it anyway.

The verifier lives in its own contract and is swapped with `setVerifier`, so circuits can change without migrating balances. This layer also has its own freeze, independent of the protocol pause. A freeze stops value from moving but still allows registration and verifier rotation, so a suspect verifier can be replaced without shutting anyone out.

## Fees

Pricing comes from one contract. `FeeSchedule.quoteFee(payer, amount)` returns the fee along with the rate used, and the app and SDK read the same view to show someone their rate before they confirm.

```
grossFee  = amount * baseFeeBps / 10_000
feeAmount = min(grossFee, feeCap)
```

Every account pays the same rate. Out of the box that's a flat 0.10%, capped at 5 USDG.

A fresh deployment charges nothing. Fees switch on only after `ProtocolAuthority.setFeeConfig(treasury, feeSchedule)` sets both values, and clearing either one switches them off everywhere. `AgentController` takes the fee from the agent's vault and keeps it out of the policy math, since policy limits govern what the agent spends, not what the protocol charges to carry the payment. `RequestLedger` adds the fee on top of the payer's bill, so the recipient gets the full amount.

## What you are trusting

- **No custody.** The protocol never holds user funds; account assets stay in each holder's own wallet. Agent vaults are the one exception, and they exist so a spend policy is enforced by code instead of promised by a server.
- **A limited admin.** The admin can reassign the other roles, operate the pause and configure fee routing. It cannot move user funds, mint anything or decrypt a balance. Handing over the admin role takes two steps (nominate, then accept), so a mistyped address can't leave the protocol without an admin.
- **A pause that still lets you act.** Pausing stops value from moving but deliberately leaves identity and agent settings editable. In an incident a user still needs to pause or revoke an agent, and a freeze that prevented that would fail at the worst possible moment.
- **A narrow compliance role.** It sets KYC tiers and that is all. It can't move funds, block a transfer or read an amount. The admin can swap it out directly with `setComplianceAuthority` without restating the admin address.

## Repository layout

```
contracts/
  src/
    core/          ProtocolAuthority, AccountRegistry
    agents/        AgentController
    payments/      RequestLedger, FeeSchedule, IFeeSchedule
    privacy/       ConfidentialToken, AltBn128, DisclosureLog, verifier interface and stub
    interfaces/    IERC20, IProtocolAuthority, IAccountRegistry
    utils/         SafeTransferLib, ReentrancyGuard, ProtocolErrors
  script/
    LaunchMainnet.s.sol    production deployment, configured through .env
    LaunchTestnet.s.sol    testnet bring-up with a mock USDG
  test/
    core/ agents/ payments/ privacy/    Foundry tests, grouped like src/
    helpers/                            mock tokens used by the tests
```

## Building and testing

You'll need [Foundry](https://book.getfoundry.sh/).

```bash
forge install foundry-rs/forge-std --no-git
forge build
forge test
```

The compiler is pinned to solc 0.8.24 targeting the Paris EVM, so the bytecode never depends on an opcode the rollup hasn't switched on. `via_ir` is enabled because `createAgent` takes a wide policy as separate arguments, more than the regular stack depth allows.

## Deploying

Copy `.env.example` to `.env` and fill in the deployer key, the compliance authority, the USDG address and, once it exists, the production verifier. Leave `TRANSFER_VERIFIER_ADDRESS` empty and the script deploys `StubTransferVerifier` instead, which is handy for bring-up but checks nothing. Replace it with `ConfidentialToken.setVerifier` before anything of real value goes in.

```bash
# Start on testnet (chain ID 46630)
forge script script/LaunchMainnet.s.sol:Deploy \
  --rpc-url robinhood_testnet --broadcast

# Then mainnet (chain ID 4663)
forge script script/LaunchMainnet.s.sol:Deploy \
  --rpc-url robinhood --broadcast --verify --verifier blockscout
```

If `TREASURY` is set, the script also deploys the fee schedule and wires up fee routing. Leaving it empty launches with fees off, which is the recommended way to start.

Verify contracts on Blockscout like this:

```bash
forge verify-contract <address> src/agents/AgentController.sol:AgentController \
  --chain-id 4663 --verifier blockscout \
  --verifier-url https://robinhoodchain.blockscout.com/api/
```

`LaunchTestnet.s.sol` exists because there is no official USDG on testnet. It mints a six-decimal stand-in, makes the deployer the compliance authority and deploys the bring-up verifier. None of that belongs anywhere near mainnet.

## Networks

| | Mainnet | Testnet |
|---|---|---|
| Chain ID | 4663 | 46630 |
| RPC | `https://rpc.mainnet.chain.robinhood.com` | `https://rpc.testnet.chain.robinhood.com` |
| Explorer | robinhoodchain.blockscout.com | explorer.testnet.chain.robinhood.com |
| Gas paid in | ETH | ETH |

## Live on testnet

Glade has been running on Robinhood Chain testnet (chain ID 46630) since 2026-10-04, deployed with `LaunchTestnet.s.sol`. It settles in the testnet USDG stand-in and uses the bring-up verifier, so none of these balances are worth anything. Each contract's source is verified on the testnet explorer.

| Contract | Address |
|---|---|
| `ProtocolAuthority` | [`0xde0cc85F9F168576eC429D8E023871c623580F96`](https://explorer.testnet.chain.robinhood.com/address/0xde0cc85F9F168576eC429D8E023871c623580F96) |
| `AccountRegistry` | [`0x7d14b198B7D4Cf50287209d102cCE39388A861b0`](https://explorer.testnet.chain.robinhood.com/address/0x7d14b198B7D4Cf50287209d102cCE39388A861b0) |
| `AgentController` | [`0x1458062e466128791044bE256eD7A866f3825Af7`](https://explorer.testnet.chain.robinhood.com/address/0x1458062e466128791044bE256eD7A866f3825Af7) |
| `RequestLedger` | [`0xa365489ee4aAdA03BF4135c342e61cc8399ef004`](https://explorer.testnet.chain.robinhood.com/address/0xa365489ee4aAdA03BF4135c342e61cc8399ef004) |
| `DisclosureLog` | [`0xf397327d4FD2Ff1B527be56D682Ba4E2b95B88A2`](https://explorer.testnet.chain.robinhood.com/address/0xf397327d4FD2Ff1B527be56D682Ba4E2b95B88A2) |
| `ConfidentialToken` | [`0x75C62a67f543045D3A6C1229628Af5fAf0097633`](https://explorer.testnet.chain.robinhood.com/address/0x75C62a67f543045D3A6C1229628Af5fAf0097633) |
| `StubTransferVerifier` | [`0xd641b9D71ABBbA5D51c0a4dF7167f77a8Dc3E95C`](https://explorer.testnet.chain.robinhood.com/address/0xd641b9D71ABBbA5D51c0a4dF7167f77a8Dc3E95C) |
| USDG (testnet stand-in) | [`0xCDF02eC32cd2A6ad7610A2e6a8fd95A9DeC98d16`](https://explorer.testnet.chain.robinhood.com/address/0xCDF02eC32cd2A6ad7610A2e6a8fd95A9DeC98d16) |
| Deployer (also admin and compliance role) | [`0x6bE6CD2eDc4E903fD5c869A3e8b766A58546D9f4`](https://explorer.testnet.chain.robinhood.com/address/0x6bE6CD2eDc4E903fD5c869A3e8b766A58546D9f4) |

This deployment has fees switched off. `setFeeConfig` was never called, so no `FeeSchedule` is connected.
