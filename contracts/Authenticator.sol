// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { ReserveStorage } from "./ReserveStorage.sol";

contract Authenticator is ReserveStorage {

    modifier minimumReserveMet(uint _protocolBalance) {
        require(
            minimumReserve <= _protocolBalance,
            "minimum reserve not met"
        );
        _;
    }

    modifier onlyApply(uint _validatorIndex) {
        bool validityCheck = (
                beneficiaries[_validatorIndex].status == Status.NOT_ACTIVE
            ) ||
            (
                beneficiaries[_validatorIndex].status == Status.ORACLE_ADD_APPROVE &&
                beneficiaries[_validatorIndex].withdrawAddress == msg.sender &&
                block.timestamp >= beneficiaries[_validatorIndex].applyTimestamp + APPLY_WINDOW
            );
        require(validityCheck, "not eligible to apply");
        _;
    }

    modifier onlyBeneficiary(address _withdrawAddress, uint _validatorIndex) {
        require(
            beneficiaries[_validatorIndex].withdrawAddress == _withdrawAddress,
            "must send tx from validator withdrawAddress"
        );
        _;
    }
    modifier onlyAddApproved(uint _validatorIndex) {
        require(
            beneficiaries[_validatorIndex].status == Status.ORACLE_ADD_APPROVE,
            "beneficiary is not approved"
        );
        _;
    }

    modifier onlyActiveBeneficiary(uint _validatorIndex) {
        require(
            beneficiaries[_validatorIndex].status == Status.ACTIVE,
            "beneficiary not active"
        );
        _;
    }

    modifier onlyWaitPeriod(uint _validatorIndex) {
        require(
            beneficiaries[_validatorIndex].status == Status.CLAIM_WAIT_PERIOD,
            "no claim pending"
        );
        _;
    }

    modifier onlyPausedClaim(uint _validatorIndex) {
        require(
            beneficiaries[_validatorIndex].status == Status.CLAIM_PAUSED,
            "no claim paused"
        );
        _;
    }

    modifier onlyTimeoutPassed(uint _validatorIndex) {
        require(block.timestamp >=
                beneficiaries[_validatorIndex].claimTimestamp +
                WAIT_PERIOD, "Cannot withdraw claim until timeout passed"
        );
        _;
    }

    modifier onlyInApplyWindow(uint _validatorIndex) {
        require((block.timestamp <=
                beneficiaries[_validatorIndex].applyTimestamp +
                APPLY_WINDOW), "Outside apply window"
        );
        _;
    }

    modifier fromWithdrawAddress(
        address _withdrawAddress,
        uint _validatorIndex
    ) {
        require(
            beneficiaries[_validatorIndex].withdrawAddress == _withdrawAddress,
            "withdrawAddress does not match"
        );
        _;
    }

    /**
     * @dev Only address that are a pool can be passed to functions marked by this modifier.
     **/
    modifier onlyPools() {
        require(msg.sender == generatorPool, "sender is not pool");
        _;
    }

    /**
     * @dev Only multisig can call functions marked by this modifier.
     **/
    modifier onlyMultiSig() {
        require(multiSig == msg.sender, "not the multiSig");
        _;
    }

    /**
     * @dev Only oracle can call functions marked by this modifier.
     **/
    modifier onlyOracle() {
        require(oracle == msg.sender, "not the oracle");
        _;
    }

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
    )ReserveStorage(
        _multiSig,
        _generatorPool,
        _wethGatewayAddr,
        _minimumProvide,
        _minimumReserve,
        _maxClaim,
        _oracle,
        _oracleGateway){
    }
}
