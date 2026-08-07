// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {LandLord} from "./LandLord.sol";
import {IResourceLottery} from "./interfaces/protocol/IResourceLottery.sol";

interface IResourceLotteryBattleManager {
    function successfulBuildRound(address player) external view returns (uint256);
}

interface IResourceLotteryTournament {
    function battleManager() external view returns (address);

    function getTablePlayers(uint256 tableId)
        external
        view
        returns (address[] memory);

    function getPlayerColonies(address player)
        external
        view
        returns (uint256[] memory);

    function playerInfo(address player)
        external
        view
        returns (
            bool registered,
            bool active,
            uint256 principalStETH,
            bool principalClaimed,
            uint256 tableId
        );

    function colonyInfo(uint256 colonyId)
        external
        view
        returns (
            address owner,
            address landLord,
            bool active,
            uint256 createdRound
        );
}

/**
 * @title ResourceLottery
 * @notice Stateless calculation of a table's round resource penalty.
 * @dev Reads tournament and LandLord state but cannot mutate either. The
 *      TournamentManager validates and applies the returned penalty.
 */
contract ResourceLottery is IResourceLottery {
    uint256 public constant BASIS_POINTS = 10_000;
    uint256 public constant PENALTY_RATIO_SMOOTHING_BPS = 500;
    uint256 public constant PENALTY_WEIGHT_NUMERATOR = 100_000_000;
    uint256 public constant MIN_RESOURCE_PENALTY_BPS = 500;
    uint256 public constant MAX_RESOURCE_PENALTY_BPS = 2_000;
    uint256 private constant RESOURCE_PENALTY_DOMAIN =
        uint256(keccak256("weighted-resource-penalty"));
    uint256 private constant RESOURCE_PENALTY_SIZE_DOMAIN =
        uint256(keccak256("weighted-resource-penalty-size"));

    struct Candidate {
        uint256 totalResource;
        uint256 resourceBalance;
        uint256 weakestColonyId;
        uint256 weakestColonyBalance;
        uint256 weakestColonyTotal;
    }

    function calculatePenalty(
        address tournament,
        uint256 roundId,
        uint256 tableId,
        uint256 randomness
    )
        external
        view
        returns (uint256 resource, uint256 colonyId, uint256 penaltyAmount)
    {
        resource = uint256(LandLord.ResourceType.Terraform);
        IResourceLotteryTournament tournamentState =
            IResourceLotteryTournament(tournament);
        address[] memory players = tournamentState.getTablePlayers(tableId);
        IResourceLotteryBattleManager battleState =
            IResourceLotteryBattleManager(tournamentState.battleManager());
        Candidate[] memory candidates = new Candidate[](players.length);
        uint256 candidateCount;

        for (uint256 i = 0; i < players.length; i++) {
            (, bool active, , , ) = tournamentState.playerInfo(players[i]);
            if (!active) continue;
            if (_completedBuild(battleState, players[i], roundId)) continue;

            Candidate memory candidate = _buildCandidate(
                tournamentState,
                players[i],
                roundId,
                resource
            );
            if (candidate.totalResource == 0) continue;
            candidates[candidateCount++] = candidate;
        }
        if (candidateCount == 0) return (resource, 0, 0);

        uint256 selectedIndex = _selectCandidate(
            roundId,
            tableId,
            randomness,
            resource,
            candidates,
            candidateCount
        );
        Candidate memory selected = candidates[selectedIndex];
        colonyId = selected.weakestColonyId;
        uint256 penaltyBps = MIN_RESOURCE_PENALTY_BPS +
            (
                uint256(
                    keccak256(
                        abi.encode(
                            randomness,
                            roundId,
                            tableId,
                            resource,
                            colonyId,
                            RESOURCE_PENALTY_SIZE_DOMAIN
                        )
                    )
                ) %
                (MAX_RESOURCE_PENALTY_BPS - MIN_RESOURCE_PENALTY_BPS + 1)
            );
        penaltyAmount =
            (
                selected.weakestColonyBalance * penaltyBps +
                BASIS_POINTS -
                1
            ) / BASIS_POINTS;
    }

    function _completedBuild(
        IResourceLotteryBattleManager battleState,
        address player,
        uint256 roundId
    ) internal view returns (bool) {
        if (address(battleState) == address(0)) return false;
        return battleState.successfulBuildRound(player) == roundId;
    }

    function _buildCandidate(
        IResourceLotteryTournament tournament,
        address player,
        uint256 roundId,
        uint256 resource
    ) internal view returns (Candidate memory candidate) {
        uint256[] memory colonies = tournament.getPlayerColonies(player);

        for (uint256 i = 0; i < colonies.length; i++) {
            uint256 colonyId = colonies[i];
            (, address landLord, bool active, uint256 createdRound) =
                tournament.colonyInfo(colonyId);
            if (!active || createdRound >= roundId) continue;

            LandLord.Resources memory balances =
                LandLord(landLord).getResources();
            uint256 colonyTotal = _totalResources(balances);
            candidate.totalResource += colonyTotal;

            uint256 balance = _resourceBalance(balances, resource);
            candidate.resourceBalance += balance;

            uint256 weakestId = candidate.weakestColonyId;
            if (
                weakestId == 0 ||
                balance * candidate.weakestColonyTotal <
                    candidate.weakestColonyBalance * colonyTotal ||
                (
                    balance * candidate.weakestColonyTotal ==
                        candidate.weakestColonyBalance * colonyTotal &&
                    colonyId < weakestId
                )
            ) {
                candidate.weakestColonyId = colonyId;
                candidate.weakestColonyBalance = balance;
                candidate.weakestColonyTotal = colonyTotal;
            }
        }
    }

    function _selectCandidate(
        uint256 roundId,
        uint256 tableId,
        uint256 randomness,
        uint256 resource,
        Candidate[] memory candidates,
        uint256 candidateCount
    ) internal pure returns (uint256 selectedIndex) {
        uint256[] memory weights = new uint256[](candidateCount);
        uint256 totalWeight;
        for (uint256 i = 0; i < candidateCount; i++) {
            uint256 ratioBps =
                candidates[i].resourceBalance * BASIS_POINTS /
                candidates[i].totalResource;
            uint256 weight = PENALTY_WEIGHT_NUMERATOR /
                (PENALTY_RATIO_SMOOTHING_BPS + ratioBps);
            weights[i] = weight;
            totalWeight += weight;
        }

        uint256 roll = uint256(
            keccak256(
                abi.encode(
                    randomness,
                    roundId,
                    tableId,
                    resource,
                    RESOURCE_PENALTY_DOMAIN
                )
            )
        ) % totalWeight;
        uint256 cumulativeWeight;
        for (uint256 i = 0; i < candidateCount; i++) {
            cumulativeWeight += weights[i];
            if (roll < cumulativeWeight) return i;
        }
    }

    function _totalResources(LandLord.Resources memory balances)
        internal
        pure
        returns (uint256)
    {
        return uint256(balances.gold) + balances.terraform + balances.attack +
            balances.defense + balances.mining + balances.infrastructure;
    }

    function _resourceBalance(
        LandLord.Resources memory balances,
        uint256 resource
    ) internal pure returns (uint256) {
        require(resource == uint256(LandLord.ResourceType.Terraform), "terraform only");
        return balances.terraform;
    }
}
