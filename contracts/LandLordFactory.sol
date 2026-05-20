// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { IERC20 } from "./interfaces/other/IERC20.sol";
import { IWETHGateway } from "./interfaces/aave/IWETHGateway.sol";
import { SafeERC20 } from "./libraries/SafeERC20.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { IPremiumGenerator } from "./interfaces/protocol/IPremiumGenerator.sol";
import {IWorldGraph} from "./interfaces/protocol/IWorldGraph.sol";

/********************
 *   LANDLORD LOGIC   *
 * 
 * There will be resources which the player uses to purchase:

uint256 public armyPoints;
uint256 public defensePoints;
uint256 public populationPoints;

Population/food will be like the health and if that ratio falls 
too low vs deposits then the user will lose control of the land and their 
interest will go to their neighbors based on the neighbors damage score.

attackPower = armyPoints * 70 
defensePower = defensePoints * 70 

 ******************** */

contract LandLord is Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =========================
    // CONFIG
    // =========================

    uint256 public splitArmy; // percent of yield to army (0-100)

    address public lord;
    address public reserve;
    address public generatorPool;
    address public wethGatewayAddr;

    // =========================
    // FINANCIAL STATE
    // =========================

    uint256 public totalDeposits;     // principal deposited
    uint256 public claimedYield;      // yield already converted to resources
    uint256 public toCentralPool;   // pending transfer to central pool (from battle losses)
    uint256 public resources;

    // =========================
    // GAME STATE
    // =========================

    uint256 public army;
    uint256 public food;

    bool public ownershipUnlocked;

    mapping(address  => uint256) public neighborDamage;

    // =========================
    // MODIFIERS
    // =========================

    modifier onlyReserve() {
        require(msg.sender == reserve, "Not reserve");
        _;
    }

    // =========================
    // INITIALIZE (CLONE SAFE)
    // =========================

    function initialize(
        address _lord,
        address _reserve,
        address _wethGatewayAddr,
        uint256 _splitArmy,
        address _generatorPool
    ) external initializer {
        require(_splitArmy <= 100, "Invalid split");

        lord = _lord;
        reserve = _reserve;
        wethGatewayAddr = _wethGatewayAddr;
        generatorPool = _generatorPool;

        splitArmy = _splitArmy;
        ownershipUnlocked = false;
    }

    // =========================
    // CORE: HARVEST YIELD → RESOURCES
    // =========================

    function _harvest() internal {
        uint256 aTokenBalance = getATokenBalance();

        if (aTokenBalance <= totalDeposits) return;

        uint256 totalEarned = aTokenBalance - totalDeposits;
        uint256 unclaimed = totalEarned - claimedYield;
        claimedYield += unclaimed;

        //if (unclaimed == 0) return;

        //uint256 armyShare = (unclaimed * splitArmy) / 100;
        //uint256 foodShare = unclaimed - armyShare;

        //army += armyShare;
        //food += foodShare;

        //claimedYield += unclaimed;
    }

    function buyResources(uint256 armyAmount, uint256 foodAmount) external onlyReserve {
        require(armyAmount + foodAmount <= claimedYield, "Not enough yield");

        army += armyAmount;
        food += foodAmount;
        claimedYield -= (armyAmount + foodAmount);
    }

    // =========================
    // DEPOSIT
    // =========================

    function addFunds(uint256 splitCentral)
        external
        payable
        onlyReserve
        nonReentrant
    {
        require(splitCentral <= 100, "Invalid split");

        uint256 centralDeposit = (msg.value * splitCentral) / 100;
        uint256 landDeposit = msg.value - centralDeposit;

        totalDeposits += landDeposit;

        address pool = IPremiumGenerator(generatorPool)
            .getLendingPoolAddress();

        // deposit to this contract
        IWETHGateway(wethGatewayAddr).depositETH{value: landDeposit}(
            pool,
            address(this),
            0
        );

        // deposit to reserve (central pool)
        if (centralDeposit > 0) {
            IWETHGateway(wethGatewayAddr).depositETH{value: centralDeposit}(
                pool,
                reserve,
                0
            );
        }
    }

    // =========================
    // WITHDRAW PRINCIPAL
    // =========================

    function withdrawPrincipal() external onlyReserve nonReentrant {
        _harvest();

        address aToken = IPremiumGenerator(generatorPool)
            .getATokenAddress();

        address pool = IPremiumGenerator(generatorPool)
            .getLendingPoolAddress();

        IERC20(aToken).safeApprove(wethGatewayAddr, 0);
        IERC20(aToken).safeApprove(wethGatewayAddr, totalDeposits);

        IWETHGateway(wethGatewayAddr).withdrawETH(
            pool,
            totalDeposits,
            lord
        );

        totalDeposits = 0;
        ownershipUnlocked = true;
    }

    // =========================
    // BATTLE LOSS (RESOURCE LEVEL)
    // =========================

    function applyBattleLoss(
        //uint256 percentLoss,
        //uint256 percentToCentral, 
        //address winner
        uint256 loss   
    ) external onlyReserve {
        //require(percentLoss <= 100, "Invalid loss");
        //require(percentToCentral <= 100, "Invalid central");

        //_harvest();

        //uint256 loss = (army * percentLoss) / 100;
        if (loss == 0) return;

        army -= loss;

        //toCentralPool += (loss * percentToCentral) / 100;
        //uint256 toWinner = loss - toCentral;

        /*address [] memory neighbors = getNeighbors();
        require(neighbors.length > 0, "No neighbors");
        require(_isNeighbor(winner), "Winner not neighbor");
        for(uint256 i = 0; i < neighbors.length; i++) {
            if(neighbors[i] == winner){
                // transfer to winner
                // IReserve(reserve).rewardWinner(toWinner);
                neighborDamage[winner] += toWinner;
            } 
        }*/

        // NOTE:
        // We are NOT transferring aTokens anymore.
        // These are virtual resources.
        // Reserve contract should track central pool.
        // Winner allocation handled externally.

        // Example hooks:
        // IReserve(reserve).addToCentralPool(toCentral);
        // IReserve(reserve).rewardWinner(toWinner);
    }

    // =========================
    // OWNERSHIP TRANSFER
    // =========================

    function assignNewLord(address _newLord) external onlyReserve {
        require(ownershipUnlocked, "Still occupied");

        lord = _newLord;
        ownershipUnlocked = false;

        // reset game state if desired
        army = 0;
        food = 0;
        claimedYield = 0;
    }

    // =========================
    // VIEWS
    // =========================

    function getResources()
        external
        view
        returns (
            uint256 _army,
            uint256 _food,
            uint256 _principal
        )
    {
        return (army, food, totalDeposits);
    }

    function previewHarvest()
        external
        view
        returns (uint256 armyOut, uint256 foodOut)
    {
        uint256 aTokenBalance = getATokenBalance();

        if (aTokenBalance <= totalDeposits) return (0, 0);

        uint256 totalEarned = aTokenBalance - totalDeposits;
        uint256 unclaimed = totalEarned - claimedYield;

        armyOut = (unclaimed * splitArmy) / 100;
        foodOut = unclaimed - armyOut;
    }

    function getATokenBalance() public view returns (uint256) {
        address aToken = IPremiumGenerator(generatorPool)
            .getATokenAddress();

        return IERC20(aToken).balanceOf(address(this));
    }

    function getNeighbors() public view returns (address[] memory) {
        return IWorldGraph(reserve).getNeighbors(address(this));
    }

    function _isNeighbor(address _addr) internal view returns (bool) {
        return IWorldGraph(reserve).isNeighbor(address(this), _addr);
    }
}
