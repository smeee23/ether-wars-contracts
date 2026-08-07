# Tournament randomness lifecycle

Battle-round randomness is requested through `TournamentManager`; callers never
provide a key hash, subscription, confirmation count, callback gas limit, or any
other parameter that could influence the request. The configured
`ChainlinkVRFProvider` owns those immutable settings.

After the Reveal window closes, any address may call
`requestRoundRandomness()`. The default request timeout is one hour and may be
changed only by the tournament administrator before the first registration.
The VRF provider is frozen at the same point.

If the active request remains unfulfilled until
`requestedAt + vrfRequestTimeout`, any address may call
`retryRoundRandomness()`. A retry permanently marks the previous request ID as
stale and creates a new active request for the same round. Attempts are not
capped: if every request fails, callers may continue retrying, but each attempt
must remain active for a full timeout. Commitments, reveals, tables, and round
deadlines are not reset by a retry.

Only the currently active request ID can finalize randomness. Callbacks for
unknown, stale, replaced, duplicate, ended-round, or previous-round requests
revert with a custom error. Once the active request fulfills, the round's VRF
state is terminal and neither another initial request nor a retry can be made.
This prevents an administrator from discarding an accepted result and prevents
request replacement while an unexpired request remains pending.

Production deployments require `VRF_COORDINATOR`, `VRF_KEY_HASH`,
`VRF_SUBSCRIPTION_ID`, `VRF_REQUEST_CONFIRMATIONS`, and
`VRF_CALLBACK_GAS_LIMIT`. `VRF_REQUEST_TIMEOUT_SECONDS` defaults to 3600.

# stETH principal and tournament yield

Production tournaments use `StETHYieldAdapter` on Ethereum mainnet. Players may
register with the configured amount of ETH or stETH. ETH is submitted directly
to Lido and the adapter retains the resulting stETH. A direct stETH entrant must
approve the adapter before calling `registerWithStETH`.

Every player receives a fixed nominal stETH principal equal to the amount the
adapter actually received. Positive stETH rebases do not increase that nominal
liability. Eliminated players may immediately claim principal, and active
players may claim once the tournament is complete. Withdrawals are always paid
in stETH; the adapter never trades stETH or requests ETH from Lido.

The finalized winner may repeatedly claim the live surplus:

```text
adapter stETH balance - outstanding nominal stETH principal
```

Surplus claims cannot consume outstanding nominal principal at the time of the
claim. Once every principal liability has been cleared, the same function acts
as a final sweep of any remaining stETH. If an emergency close has multiple
survivors, no winner is fabricated and surplus remains held by the adapter.

If a negative rebase leaves the adapter below its nominal liabilities,
principal withdrawals are paid at the live common coverage ratio. This avoids
giving early claimants preferential recovery. A later negative rebase can still
reduce coverage after a winner has already withdrawn a previously valid
surplus; this is an explicit consequence of aggressive live-surplus claiming.

The production deployment script accepts only Ethereum mainnet, uses canonical
mainnet stETH by default, and supports `STETH_ADDRESS` and
`LIDO_REFERRAL_ADDRESS` configuration. Local deployments use `StETHMock`.

## Virtual resource settlement

Gold allocations into Attack, Defense, Mining, and Infrastructure
are permanent and are applied from the committed round plan before battle
scoring. Attack is offensive-only; Defense is used by DEFEND and attacked BUILD
actions. A successful uncontested BUILD reduces each active eligible colony's
effective population-growth round by one. Population is `10 + max(round - successful
BUILD count, 0) * 50`, and a colony is eliminated when its gold is less than or
equal to that population threshold.

After every table resolves, finalization runs in bounded phases: Mining yield,
population solvency checks, automatic expansion, then table compaction and
balancing. Both Mining and population checks process the tournament player list
in bounded batches. Mining and its Infrastructure multiplier become eligible
one round after purchase.
