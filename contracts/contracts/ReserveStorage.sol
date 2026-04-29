// SPDX-License-Identifier: MIT
pragma solidity 0.8.9;

/**
 * @title ReserveStorage
 * @author SLI
 * @notice Ethereum Slashing Insurance (SLI) ReserveStorage contract
 **/
contract ReserveStorage {
    mapping(address => address[]) public playerNeighbors;

    ///////////OLD STORGAE////////////////

    //address of the FunctionsConsumer contract
    address oracle;
    address public oracleGateway;

    //Aave WETHGateway
    address immutable wethGatewayAddr;

    // window after claim approved before payout
    uint256 public constant WAIT_PERIOD = 1 days;//shorter for testnet

    // window for deposit after application accepted
    uint256 public constant APPLY_WINDOW = 2 days;

    //stages in the Policy process
    enum Status {
        NOT_ACTIVE,
        ACTIVE,
        AWAIT_ORACLE_ADD,
        ORACLE_ADD_APPROVE,
        AWAIT_ORACLE_CLAIM,
        CLAIM_WAIT_PERIOD,
        CLOSED,
        CLAIM_PAUSED
    }

    //stores info about each covered validator
    struct Beneficiary {
        Status status;
        address withdrawAddress;
        uint claimTimestamp;
        uint applyTimestamp;
        uint loss;
    }

    //maps validator index to Beneficiary obj
    mapping(uint => Beneficiary) beneficiaries;
    //maps all incoming applications to validatorIds
    mapping(address => uint[]) depositors;

    address public immutable generatorPool;

    //multiSig with
    address public immutable multiSig;

    //minimum amount of ETH that ben be provided to Claims Fund
    uint public minimumProvide;
    //minimum required for withdrawing ETH for sliETH
    uint public minimumReserve;
    //maximum slashing loss that can be automatically dispersed
    uint public maxClaim;

    /**
     * @dev Constructor.
     */
    constructor(
        address _multiSig,
        address _generatorPool,
        address _wethGatewayAddr,
        uint _minimumProvide,
        uint _minimumReserve,
        uint _maxClaim,
        address _oracle,
        address _oracleGateway
    ){
        multiSig = _multiSig;
        generatorPool = _generatorPool;
        wethGatewayAddr = _wethGatewayAddr;
        minimumProvide = _minimumProvide;
        minimumReserve = _minimumReserve;
        maxClaim = _maxClaim;
        oracle = _oracle;
        oracleGateway = _oracleGateway;
    }
}
