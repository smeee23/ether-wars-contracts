// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "./WorldGraph.sol";

interface ILandLord {
    function initialize(
        address _lord,
        address _wethGatewayAddr,
        uint256 _splitArmy,
        address _generatorPool,
        address _map
    ) external;
}

contract LandLordFactory is WorldGraph {

    using Clones for address;

    // -----------------------------------------------------------------------
    // State
    // -----------------------------------------------------------------------

    address public immutable baseLandLord;   // implementation contract to clone
    address public immutable wethGatewayAddr;
    address public immutable generatorPool;

    mapping(address => address) public lordToClone;  // player => their LandLord clone
    mapping(address => bool)    public isClone;

    address[] public allClones;

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    event LandLordCreated(
        address indexed lord,
        address indexed clone,
        uint256 deposit,
        uint256 neighborCount
    );

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    constructor(
        address _baseLandLord,
        address _wethGatewayAddr,
        address _generatorPool
    ) {
        require(_baseLandLord   != address(0), "invalid base");
        require(_wethGatewayAddr != address(0), "invalid weth gateway");
        require(_generatorPool  != address(0), "invalid generator pool");

        baseLandLord    = _baseLandLord;
        wethGatewayAddr = _wethGatewayAddr;
        generatorPool   = _generatorPool;
    }

    // -----------------------------------------------------------------------
    // Clone creation
    // -----------------------------------------------------------------------

    /// @param _splitArmy   Army split percentage (1–99)
    ///                     Pass address(0) only for the very first player.
    function createLandLord(uint256 _splitArmy) external payable {
        require(msg.value >= MIN_DEPOSIT,           "Deposit too small");
        require(lordToClone[msg.sender] == address(0), "Already has a LandLord");
        require(_splitArmy > 0 && _splitArmy < 100, "Split must be between 1 and 99");

        // 1. Register the player in the graph (handles anchor + neighbor seeding)
        _registerPlayer(msg.sender, msg.value);

        // 2. Deploy the clone
        address clone = baseLandLord.clone();

        // 3. Initialize it — factory passes itself as _map
        ILandLord(clone).initialize(
            msg.sender,
            wethGatewayAddr,
            _splitArmy,
            generatorPool,
            address(this)      // factory IS the map
        );

        // 4. Forward the deposit to the clone which deposits into AAVE
        ILandLord(clone).addFunds{value: msg.value}();

        // 5. Record
        lordToClone[msg.sender] = clone;
        isClone[clone]          = true;
        allClones.push(clone);

        emit LandLordCreated(msg.sender, clone, msg.value, neighborCount(msg.sender));
    }

    fuunction addFundsToClone() external payable {
        require(msg.value >= MIN_DEPOSIT,           "Deposit too small");
        address clone = lordToClone[msg.sender];
        require(clone != address(0), "Player has no land");

        ILandLord(clone).addFunds{value: msg.value}();
    }

    function _removePlayer(address player) internal override {
        super._removePlayer(player);
        lordToClone[player] = address(0);
    }

    // -----------------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------------

    function allClonesLength() external view returns (uint256) {
        return allClones.length;
    }

    function getClone(address lord) external view returns (address) {
        return lordToClone[lord];
    }
}