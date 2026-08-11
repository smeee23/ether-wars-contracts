const { ethers, network } = require("hardhat");
const fs = require("fs");
const path = require("path");

const ATTACK = 0;
const COMMIT_DURATION = 4 * 60 * 60;
const REVEAL_DURATION = 2 * 60 * 60;
const LOCAL_CHAIN_ID = 31337;

function readPositiveInteger(name, fallback) {
  const value = process.env[name] || String(fallback);
  if (!/^\d+$/.test(value) || Number(value) < 1) {
    throw new Error(`${name} must be a positive integer`);
  }
  return Number(value);
}

async function advanceTime(seconds) {
  await network.provider.send("evm_increaseTime", [seconds]);
  await network.provider.send("evm_mine");
}

async function completeFinalization(tournament, admin) {
  while (Number(await tournament.state()) === 1) {
    const phase = Number(await tournament.finalizationPhase());
    if (phase === 0) return;
    if (phase === 1) {
      await (await tournament.processMiningBatch(25)).wait();
    } else if (phase === 2) {
      await (await tournament.processPopulationBatch(25)).wait();
    } else if (phase === 3) {
      await (await tournament.processAutomaticExpansionBatch(25)).wait();
    } else if (phase === 4) {
      await (await tournament.processTableCompactionBatch(25)).wait();
    } else if (phase === 5) {
      await (await tournament.processTableConsolidationBatch(25)).wait();
    } else if (phase === 6) {
      await (await tournament.processBalanceScanBatch(50)).wait();
    } else if (phase === 7) {
      await (await tournament.applyBalanceMove()).wait();
    } else if (phase === 8) {
      await (await tournament.connect(admin).finalizeRound()).wait();
    } else {
      throw new Error(`Unknown finalization phase ${phase}`);
    }
  }
}

async function makeSignedReveal(
  tournament,
  battleManager,
  player,
  target,
  roundId,
  index
) {
  const playerColonies = await tournament.getPlayerColonies(player.address);
  const targetColonies = await tournament.getPlayerColonies(target.address);
  const plan = {
    action: {
      actionType: ATTACK,
      target: target.address,
      amount: 10,
      sourceColonyId: playerColonies[0],
      targetColonyId: targetColonies[0],
    },
    allocations: [],
  };
  const salt = ethers.utils.keccak256(
    ethers.utils.defaultAbiCoder.encode(
      ["string", "uint256", "uint256", "address"],
      ["ether-wars-local-simulation", roundId, index, player.address]
    )
  );
  const hash = await battleManager.computePlanCommitHash(
    player.address,
    plan,
    salt,
    roundId
  );
  await (await battleManager.connect(player).commitPlan(hash)).wait();

  return {
    player: player.address,
    plan,
    salt,
    signature: await player.signMessage(ethers.utils.arrayify(hash)),
  };
}

async function main() {
  const rounds = readPositiveInteger("SIMULATION_ROUNDS", 3);
  const playerCount = readPositiveInteger("SIMULATION_PLAYERS", 4);
  if (playerCount < 2) throw new Error("SIMULATION_PLAYERS must be at least 2");
  if (playerCount > 9) {
    throw new Error("SIMULATION_PLAYERS cannot exceed one nine-player table");
  }

  const manifestPath = path.resolve(
    process.env.DEPLOYMENT_MANIFEST_PATH ||
      path.join("deployments", `${network.name}.json`)
  );
  const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  const { chainId } = await ethers.provider.getNetwork();
  if (chainId !== LOCAL_CHAIN_ID || manifest.chainId !== String(chainId)) {
    throw new Error("Round simulation requires a matching local chainId 31337 manifest");
  }

  const signers = await ethers.getSigners();
  if (signers.length < playerCount + 1) {
    throw new Error(`Simulation requires ${playerCount + 1} unlocked local accounts`);
  }
  const admin = signers[0];
  const players = signers.slice(1, playerCount + 1);
  const tournament = await ethers.getContractAt(
    "TournamentManager",
    manifest.tournamentAddress
  );
  const battleManager = await ethers.getContractAt(
    "BattleManager",
    manifest.battleManagerAddress
  );
  const vrfProvider = await ethers.getContractAt(
    "VRFProviderMock",
    manifest.vrfProviderAddress
  );

  for (const player of players) {
    await (
      await tournament.connect(player).registerWithETH({
        value: ethers.utils.parseEther("1"),
      })
    ).wait();
  }
  await (await tournament.connect(admin).startTournament()).wait();

  for (let roundIndex = 0; roundIndex < rounds; roundIndex++) {
    await (await tournament.connect(admin).startBattleRound()).wait();
    const roundId = Number(await battleManager.currentRound());
    const reveals = [];

    for (let index = 0; index < players.length; index++) {
      const targetOffset = (roundIndex % (players.length - 1)) + 1;
      const target = players[(index + targetOffset) % players.length];
      reveals.push(
        await makeSignedReveal(
          tournament,
          battleManager,
          players[index],
          target,
          roundId,
          index
        )
      );
    }

    await advanceTime(COMMIT_DURATION + 1);
    await (await battleManager.connect(admin).batchReveal(reveals)).wait();
    await advanceTime(REVEAL_DURATION + 1);

    const requestId = await vrfProvider.nextRequestId();
    await (await tournament.requestRoundRandomness()).wait();
    await (await vrfProvider.fulfill(requestId, 1000 + roundId)).wait();

    const tableCount = Number(
      await battleManager.roundRequiredTableCount(roundId)
    );
    for (let tableId = 1; tableId <= tableCount; tableId++) {
      await (
        await tournament.connect(admin).resolveTableConflicts(tableId, roundId)
      ).wait();
    }
    await (await tournament.connect(admin).endBattleRound()).wait();
    await completeFinalization(tournament, admin);

    console.log(
      `Completed round ${roundId}: seed=${1000 + roundId}, ` +
        `activePlayers=${await tournament.activePlayerCount()}`
    );
  }

  console.log(`Simulation complete at block ${await ethers.provider.getBlockNumber()}`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
