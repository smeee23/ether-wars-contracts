// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

library GameTypes {
    enum ActionType {
        ATTACK,
        DEFEND,
        BUILD
    }

    struct Action {
        ActionType actionType;
        address target;
        uint256 amount;
        uint256 sourceColonyId;
        uint256 targetColonyId;
    }

    struct ColonyAllocation {
        uint256 colonyId;
        uint256 food;
        uint256 water;
        uint256 oxygen;
        uint256 shelter;
        uint256 army;
    }

    struct RoundPlan {
        Action action;
        ColonyAllocation[] allocations;
        bool claimExpansion;
    }
}
