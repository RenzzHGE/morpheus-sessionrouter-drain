# Morpheus SessionRouter — fundingAccount Drain PoC

Foundry PoC for a reported vulnerability in Morpheus LumerinDiamond (SessionRouter facet) on Base mainnet:
a disputed multi-day session close refunds ~99.7% of the user's stake while the provider is paid
`(closedAt - openedAt) * pricePerSecond` in full from the protocol `fundingAccount`; the provider's own
stake returns in full after the 365-day reward limiter period.

## Run (one command)

```bash
forge test --fork-url https://mainnet.base.org -vv
```

Only prerequisite: foundry. The fork is pinned to block 58,420,000 inside the test. No privileged
accounts are used; the attacker is an ordinary address anyone can control.

## What the tests assert

- `test_candidate1_disputed_multiday_close` — disputed close drains exactly **1,728 MOR** from the
  `fundingAccount` while the user's net cost is exactly **1 MOR**; provider nets >1,000 MOR.
- `test_candidate1b_nodispute_close_refunds_full_stake` — no-dispute early close refunds the full stake.
- `test_candidate2_claimForProvider_underflow_after_nodispute_early_close` — `claimForProvider`
  uint256 underflow (temporary claim DoS, <= 1 day) after a noDispute early close.

Target: LumerinDiamond `0x6aBE1d282f72B474E54527D93b979A4f64d3030a` (Base), Appendix A scope of
https://mor.org/bug-bounty. Read-only fork; no mainnet transactions were sent.
