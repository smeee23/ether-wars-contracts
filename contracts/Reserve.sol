// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;


import {SafeERC20} from "./libraries/SafeERC20.sol";
import {IERC20} from "./interfaces/other/IERC20.sol";
import {IWETHGateway} from "./interfaces/aave/IWETHGateway.sol";
import {IPremiumGenerator} from "./interfaces/protocol/IPremiumGenerator.sol";
import { IOracleGateway } from "./interfaces/protocol/IOracleGateway.sol";
import {SlashingInsuranceETH} from "./SlashingInsuranceETH.sol";
import { Authenticator } from "./Authenticator.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

//AAVE V2
import {ILendingPool} from "./interfaces/aave/ILendingPool.sol";
import {ILendingPoolAddressesProvider} from "./interfaces/aave/ILendingPoolAddressesProvider.sol";
import {IProtocolDataProvider} from "./interfaces/aave/IProtocolDataProvider.sol";


/**
 * @title Reserve
 * @author SLI
 * @notice Ethereum Slashing Insurance (SLI) Reserve contract
 *
 * This is a proof of concept contract for lossless Ethereum slashing insurance
 *
 * Lossless because premiums are refundable, when the insurance
 * agreement is terminated.
 *
 * Aave v2 is used to generate interest from beneficiary premium deposits
 * Premium is returned to beneficiary when Policy terminated (validator
 * exits from staking, no longer wants insurance, or claim is paid).
 * Interest is accrued in the Reserve to cover validator slashing claims.
 *
 * Chainlink Functions is used as an oracle to access the validator stats
 * such as slashing, loss, and withdrawal credentials associated with a
 * validator Id.
 *
 * Claims Fund is funded by sliETH.
 *
 * Reserve contract controls deposit calls to Aave for funds held in Reserve.
 *
 * @dev Deposits, withdraws, and claims for Aave Pools
 **/
contract Reserve is ReentrancyGuard, Authenticator{
    using SafeERC20 for IERC20;

    SlashingInsuranceETH immutable sliETH;

    event DenyApplication(uint validatorIndex,address withdrawAddress,uint8 reason);
    event ApproveApplication( uint validatorIndex, address withdrawAddress);
    event ProvideInsurance(address depositor, uint ethAmount);
    event WithdrawInsurance(address depositor, uint ethAmount, uint sliETHAmount);
    event DenyClaim(uint validatorIndex,address withdrawAddress,uint8 reason);
    event AcceptClaim(uint validatorIndex,address withdrawAddress);
    event AddBeneficiary(uint validatorIndex, address withdrawAddress);
    event WithdrawBeneficiary(uint validatorIndex, address withdrawAddress);
    event MakeClaim(uint validatorIndex);
    event ProcessClaim(address beneficiary, uint amount, uint8 result);

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
    ) Authenticator(
        _multiSig,
        _generatorPool,
        _wethGatewayAddr,
        _minimumProvide,
        _minimumReserve,
        _maxClaim,
        _oracle,
        _oracleGateway
    ){
        sliETH = new SlashingInsuranceETH();
    }

    /**
     * @dev Receive function that allows receiving ETH and automatically provides insurance coverage.
     *
     * Requirements:
     * None.
     *
     * Modifiers:
     * None.
     *
     *
     */
    receive() external payable {
        provideInsurance();
    }

    /**
     * @dev Fallback function that allows receiving ETH and automatically provides insurance coverage.
     *
     * Requirements:
     * None.
     *
     * Modifiers:
     * None.
     *
     *
     */
    fallback() external payable {
        provideInsurance();
    }

    /**
    * @dev Provides insurance coverage by depositing ETH and minting sliETH tokens.
    *
    * Events:
    *   - ProvideInsurance: emitted after the insurance coverage is successfully provided.
    * Requirements:
    *   - The value must be greater than or equal to the minimum required amount.
    * Modifiers:
    *   - nonReentrant: prevents reentrancy issues during the function execution.
    *
    *
    */
    function provideInsurance() public payable nonReentrant {
        require(
            msg.value >= minimumProvide,
            "value must be greater than minimum"
        );
        sliETH.mint(msg.sender, msg.value);
        address aaveLendingPool = IPremiumGenerator(generatorPool).getLendingPoolAddress();
        IWETHGateway(wethGatewayAddr).depositETH{value: msg.value}(aaveLendingPool, address(this), 0);
        emit ProvideInsurance(msg.sender, msg.value);
    }

    /**
     * @dev Withdraws insurance coverage by swapping a specified amount of sliETH tokens for ETH.
     * @param _sliETHAmount The amount of sliETH tokens to swap for ETH.
     *
     * Events:
     * - WithdrawInsurance: emitted after the insurance coverage is successfully withdrawn.
     *
     * Requirements:
     * - The reserve must have sufficient funds to cover the requested ETH amount.
     *
     * Modifiers:
     * - nonReentrant: prevents reentrancy issues during the function execution.
     *
     *
     */
    function withdrawInsurance(uint _sliETHAmount) external nonReentrant {
        uint requestedETH = sliETH.getETHValue(_sliETHAmount);
        require(
            minimumReserve < (getProtocolBalance() - requestedETH),
            "reserve insufficient to withdraw insurance"
        );
        sliETH.burn(msg.sender, _sliETHAmount);
        _processOutflow(msg.sender, requestedETH);
        emit WithdrawInsurance(msg.sender, requestedETH, _sliETHAmount);
    }

    /**
     * @dev Processes outflow of ETH by withdrawing from Aave pools and transferring it to the specified recipient.
     * @param _to The address to transfer the requested ETH.
     * @param requestedETH The amount of ETH to be transferred.
     *
     * Requirements:
     * - Sufficient aToken balance must be available to cover the requestedETH amount.
     *
     * Modifiers:
     * None.
     *
     *
     */
    function _processOutflow(address _to, uint requestedETH) internal {
        //harvest aave pools for outflow
        uint aTokenBalance = getReserveATokenBalance();
        if(aTokenBalance < requestedETH){
            _harvestInterest();
        }

        address aTokenAddress = IPremiumGenerator(generatorPool)
            .getATokenAddress();
        IERC20(aTokenAddress).safeApprove(wethGatewayAddr, 0);
        IERC20(aTokenAddress).safeApprove(wethGatewayAddr, requestedETH);
        address aaveLendingPool = IPremiumGenerator(generatorPool)
            .getLendingPoolAddress();
        IWETHGateway(wethGatewayAddr).withdrawETH(
            aaveLendingPool,
            requestedETH,
            _to
        );
    }

    /**
     * @dev Allows a validator to apply for insurance coverage.
     * @param _validatorIndex The index of the validator applying for coverage.
     *
     * Requirements:
     * - Only validators with designated Status can call this function.
     *
     * Modifiers:
     * - onlyApply: restricts the function to be called only by the designated Status.
     *
     *
     */
    function applyForCoverage(
        uint _validatorIndex
    ) external onlyApply(_validatorIndex) {
        IOracleGateway(oracleGateway).callOracle(Strings.toString(_validatorIndex));
        beneficiaries[_validatorIndex] = Beneficiary(
            Status.AWAIT_ORACLE_ADD,
            msg.sender,
            0,
            0,
            0
        );
        depositors[msg.sender].push(_validatorIndex);
    }

    /**
     * @dev Adds a beneficiary for a specific validator to receive insurance payouts.
     * @param _withdrawAddress The address to which the insurance payouts will be sent.
     * @param _validatorIndex The index of the validator for which the beneficiary is being added.
     *
     * Requirements:
     * - Only an approved address can call this function for the specified validator.
     * - Only the beneficiary can add a beneficiary.
     * - The function can only be called within the apply window.
     * - The caller must be a valid pool contract.
     *
     * Modifiers:
     * - onlyAddApproved: restricts the function to be called only by an approved address for the validator.
     * - onlyBeneficiary: restricts the function to be called by the beneficiary.
     * - onlyInApplyWindow: restricts the function to be called only within the apply window.
     * - onlyPools: restricts the function to be called only by a valid pool contract.
     *
     *
     */
    function addBeneficiary(
        address _withdrawAddress,
        uint _validatorIndex
    )
        external
        onlyAddApproved(_validatorIndex)
        onlyBeneficiary(_withdrawAddress, _validatorIndex)
        onlyInApplyWindow(_validatorIndex)
        onlyPools
    {
        beneficiaries[_validatorIndex].status = Status.ACTIVE;
        emit AddBeneficiary(_validatorIndex, _withdrawAddress);
    }

    /**
     * @dev Handles the response from the oracle regarding a validator's insurance claim or beneficiary addition.
     * @param _validatorIndex The index of the validator for which the oracle response is received.
     * @param _slashed The status indicating whether the validator has been slashed (1) or not slashed (0).
     * @param _withdrawAddress The address to which the insurance payouts will be sent.
     * @param _loss The amount of loss incurred by the validator (in wei).
     *
     * Requirements:
     * - Only the oracle contract can call this function.
     *
     * Modifiers:
     * - onlyOracle: restricts the function to be called only by the oracle contract.
     *
     *
     */
    function oracleResponse(
        uint _validatorIndex,
        uint8 _slashed,
        address _withdrawAddress,
        uint _loss
    ) external onlyOracle {
        if (beneficiaries[_validatorIndex].status == Status.AWAIT_ORACLE_CLAIM) {
            _oracleClaimResponse(_validatorIndex, _slashed, _withdrawAddress, _loss);
        }
        else if (beneficiaries[_validatorIndex].status == Status.AWAIT_ORACLE_ADD) {
            _oracleAddBeneResponse(_validatorIndex, _slashed, _withdrawAddress);
        }
        else{
            return;
        }
    }

    /**
     * @dev Handles the oracle response for adding a beneficiary for a validator.
     * @param _validatorIndex The index of the validator for which the oracle response is received.
     * @param _slashed The status indicating whether the validator has been slashed (1) or not slashed (0).
     * @param _withdrawAddress The address to which the insurance payouts will be sent.
     *
     * Requirements:
     * None.
     *
     * Modifiers:
     * None.
     *
     *
     */
    function _oracleAddBeneResponse(
        uint _validatorIndex,
        uint8 _slashed,
        address _withdrawAddress
    ) internal {
        //check withdraw address with oracle reponse
        //check validator is active with oracle response
        if (
            beneficiaries[_validatorIndex].withdrawAddress != _withdrawAddress ||
            _slashed == 1
        ) {
            beneficiaries[_validatorIndex].withdrawAddress = address(0);
            beneficiaries[_validatorIndex].status = Status.NOT_ACTIVE;
            emit DenyApplication(
                _validatorIndex,
                _withdrawAddress,
                0 //address not correct or validator slashed
            );
        }
        else {
            beneficiaries[_validatorIndex].status = Status.ORACLE_ADD_APPROVE;
            beneficiaries[_validatorIndex].applyTimestamp = block.timestamp;
            emit ApproveApplication(_validatorIndex, _withdrawAddress);
        }
    }

    /**
     * @dev Handles the oracle response for a validator's insurance claim.
     * @param _validatorIndex The index of the validator for which the oracle response is received.
     * @param _slashed The status indicating whether the validator has been slashed (1) or not slashed (0).
     * @param _withdrawAddress The address to which the insurance payouts will be sent.
     * @param _loss The amount of loss incurred by the validator (in wei).
     *
     * Requirements:
     * None.
     *
     * Modifiers:
     * None.
     *
     *
     */
    function _oracleClaimResponse(
        uint _validatorIndex,
        uint8 _slashed,
        address _withdrawAddress,
        uint _loss
    ) internal {
        //check withdraw address with oracle reponse
        if (
            beneficiaries[_validatorIndex].withdrawAddress != _withdrawAddress
        ) {
            beneficiaries[_validatorIndex].status = Status.ACTIVE;
            emit DenyClaim(
                _validatorIndex,
                _withdrawAddress,
                0//"withdrawAddress incorrect"
            );
        }
        //check if slashed
        else if (_slashed == 0 || _loss == 0) {
            beneficiaries[_validatorIndex].status = Status.ACTIVE;
            emit DenyClaim(
                _validatorIndex,
                _withdrawAddress,
                1//"not slashed"
            );
        }
        else {
            if(_loss > maxClaim){
                beneficiaries[_validatorIndex].status = Status.CLAIM_PAUSED;
                emit DenyClaim(
                _validatorIndex,
                _withdrawAddress,
                2//exceeds max claim and has to be reviewed
            );
            }
            else{
                beneficiaries[_validatorIndex].status = Status.CLAIM_WAIT_PERIOD;
                emit AcceptClaim(_validatorIndex, _withdrawAddress);
            }
            beneficiaries[_validatorIndex].claimTimestamp = block.timestamp;
            beneficiaries[_validatorIndex].loss = _loss;
        }
    }

    /**
     * @dev Initiates an insurance claim for a specific validator.
     * @param _validatorIndex The index of the validator for which the claim is being made.
     *
     * Requirements:
     * - The claim must be made from the beneficiary's withdraw address.
     * - The beneficiary must be active for the specified validator.
     *
     * Modifiers:
     * - fromWithdrawAddress: restricts the function to be called only from the beneficiary's withdraw address.
     * - onlyActiveBeneficiary: restricts the function to be called only by an active beneficiary for the validator.
     *
     *
     */
    function makeClaim(
        uint _validatorIndex
    )
        public
        fromWithdrawAddress(msg.sender, _validatorIndex)
        onlyActiveBeneficiary(_validatorIndex)
    {
        IOracleGateway(oracleGateway).callOracle(Strings.toString(_validatorIndex));
        beneficiaries[_validatorIndex].status = Status.AWAIT_ORACLE_CLAIM;
    }

    /**
     * @dev Pays out an insurance claim for a specific validator.
     * @param _validatorIndex The index of the validator for which the claim is being paid.
     *
     * Requirements:
     * - The validator Status must = CLAIM_WAIT_PERIOD.
     * - The timeout period must have passed.
     *
     * Modifiers:
     * - onlyWaitPeriod: restricts the function to be called only for validators with Status = CLAIM_WAIT_PERIOD.
     * - onlyTimeoutPassed: restricts the function to be called only after the timeout period has passed.
     *
     *
     */
    function payClaim(
        uint _validatorIndex
    )
        external
        onlyWaitPeriod(_validatorIndex)
        onlyTimeoutPassed(_validatorIndex)
    {
        address withdrawAddress = beneficiaries[_validatorIndex]
            .withdrawAddress;
        uint loss = beneficiaries[_validatorIndex].loss;
        uint payout = loss + IPremiumGenerator(generatorPool).premiumDeposit();
        _processOutflow(
            withdrawAddress,
            payout
        );
        beneficiaries[_validatorIndex].status = Status.CLOSED;
        emit ProcessClaim(
            withdrawAddress,
            loss,
            0//approve
            );
    }

    /**
     * @dev Denies an insurance claim for a specific validator (for malicious activity).
     * @param _validatorIndex The index of the validator for which the claim is being denied.
     *
     * Requirements:
     * - The function can only be called by a multi-signature account.
     * - The claim must be in the paused state.
     *
     * Modifiers:
     * - onlyMultiSig: restricts the function to be called only by a multi-signature account.
     * - onlyPausedClaim: restricts the function to be called only for validators with paused claims.
     *
     *
     */
    function denyClaim(
        uint _validatorIndex
    ) public onlyMultiSig onlyPausedClaim(_validatorIndex) {
        beneficiaries[_validatorIndex].status = Status.CLOSED;
        emit ProcessClaim(
            beneficiaries[_validatorIndex].withdrawAddress,
            0,
            1//deny
        );
    }

    /**
     * @dev Pauses an insurance claim for a specific validator.
     * @param _validatorIndex The index of the validator for which the claim is being paused.
     *
     * Requirements:
     * - The function can only be called by a multi-signature account.
     * - The claim must be in the wait period.
     *
     * Modifiers:
     * - onlyMultiSig: restricts the function to be called only by a multi-signature account.
     * - onlyWaitPeriod: restricts the function to be called only for validators in the wait period.
     *
     *
     */
    function pauseClaim(
        uint _validatorIndex
    ) public onlyMultiSig onlyWaitPeriod(_validatorIndex) {
        beneficiaries[_validatorIndex].status = Status.CLAIM_PAUSED;
        emit ProcessClaim(
            beneficiaries[_validatorIndex].withdrawAddress,
            0,
            2//pause
        );
    }

    /**
     * @dev Unpauses an insurance claim for a specific validator.
     * @param _validatorIndex The index of the validator for which the claim is being unpaused.
     *
     * Requirements:
     * - The function can only be called by a multi-signature account.
     * - The claim must be in the paused state.
     *
     * Modifiers:
     * - onlyMultiSig: restricts the function to be called only by a multi-signature account.
     * - onlyPausedClaim: restricts the function to be called only for validators with paused claims.
     *
     *
     */
    function unpauseClaim(
        uint _validatorIndex
    )
        public
        onlyMultiSig
        onlyPausedClaim(_validatorIndex)
    {
        beneficiaries[_validatorIndex].status = Status.CLAIM_WAIT_PERIOD;
        emit ProcessClaim(
            beneficiaries[_validatorIndex].withdrawAddress,
            0,
            3//"unpause"
        );
    }

    /**
     * @dev Resets the status of an insurance claim for a specific validator.
     * @param _validatorIndex The index of the validator for which the claim is being reset.
     *
     * Requirements:
     * - The function can only be called by a multi-signature account.
     *
     * Modifiers:
     * - onlyMultiSig: restricts the function to be called only by a multi-signature account.
     *
     *
     */
    function resetClaim(
        uint _validatorIndex
    ) public onlyMultiSig {
        beneficiaries[_validatorIndex].status = Status.ACTIVE;
        emit ProcessClaim(
            beneficiaries[_validatorIndex].withdrawAddress,
            0,
            4//"reset"
        );
    }

    /**
     * @dev Withdraws a beneficiary from the insurance coverage for a specific validator.
     * @param _withdrawAddress The withdraw address of the beneficiary.
     * @param _validatorIndex The index of the validator for which the beneficiary is being withdrawn.
     *
     * Requirements:
     * - The withdraw address must match the beneficiary's withdraw address for the validator.
     * - The beneficiary must be active for the specified validator.
     * - The caller must be a generator pool
     *
     * Modifiers:
     * - fromWithdrawAddress: withdraw address must match the beneficiary's withdraw address for the validator.
     * - onlyActiveBeneficiary: restricts the function to be called only by an active beneficiary for the validator.
     * - onlyPools: restricts the function to be called only by specific pools.
     *
     *
     */
    function withdrawBeneficiary(
        address _withdrawAddress,
        uint _validatorIndex
    )
        external
        fromWithdrawAddress(_withdrawAddress, _validatorIndex)
        onlyActiveBeneficiary(_validatorIndex)
        onlyPools
    {
        beneficiaries[_validatorIndex].status = Status.NOT_ACTIVE;
        emit WithdrawBeneficiary(_validatorIndex, _withdrawAddress);
    }

    /**
     * @dev Harvests the accumulated interest from the premium generator contract.
     *
     */
    function _harvestInterest() internal {
        uint256 amount = IPremiumGenerator(generatorPool).withdrawInterest();
    }

    /**
     * @dev Retrieves the address of the SLIETH token contract.
     *
     * @return The address of the SLIETH token contract.
     */
    function getSlashingInsuranceETHAddress() public view returns (address) {
        return address(sliETH);
    }

    /**
     * @dev Retrieves the balance of SLIETH tokens for a specific depositor.
     * @param _depositor The address of the depositor.
     *
     * @return The balance of SLIETH tokens for the specified depositor.
     */
    function getSlashingInsuranceETHBalance(
        address _depositor
    ) public view returns (uint) {
        return IERC20(getSlashingInsuranceETHAddress()).balanceOf(_depositor);
    }

    /**
     * @dev Retrieves the validator IDs associated with a specific withdraw address.
     * @param _withdrawAddress The address of the withdraw address.
     *
     * @return An array of validator IDs associated with the specified withdraw address.
     */
    function getDepositorValidatorIds(address _withdrawAddress) public view returns(uint[] memory){
        return depositors[_withdrawAddress];
    }

    /**
     * @dev Retrieves the balance of aTokens in the reserve.
     *
     * @return The balance of aTokens in the reserve.
     */
    function getReserveATokenBalance() public view returns (uint) {
        address aTokenAddress = IPremiumGenerator(generatorPool)
                .getATokenAddress();

        return IERC20(aTokenAddress).balanceOf(address(this));
    }

    /**
     * @dev Retrieves the total balance of the protocol, including ETH balance, unclaimed interest, and aTokens in the reserve.
     *
     * @return The total balance of the protocol.
     */
    function getProtocolBalance() public view returns (uint) {
        return (
            address(this).balance +
            IPremiumGenerator(generatorPool).getUnclaimedInterest() +
            getReserveATokenBalance()
        );
    }

    /**
     * @dev Retrieves the total supply of SLIETH tokens.
     *
     * @return The total supply of SLIETH tokens.
     */
    function getSliETHTotalSupply() public view returns (uint) {
        return IERC20(getSlashingInsuranceETHAddress()).totalSupply();
    }

    /**
     * @dev Retrieves the conversion rate between SLIETH and ETH.
     *
     * @return The conversion rate between SLIETH and ETH.
     */
    function getSliETHConversion() public view returns (uint256) {
        return sliETH.getETHValuePerSliETH();
    }

    /**
     * @dev Retrieves the status of a beneficiary for a specific validator index.
     * @param _validatorIndex The index of the validator.
     *
     * @return status The status of the beneficiary.
     */
    function getBeneficiaryStatus(
        uint _validatorIndex
    ) public view returns (Status status) {
        status = beneficiaries[_validatorIndex].status;
    }

    /**
     * @dev Retrieves the withdraw address associated with a specific validator index.
     * @param _validatorIndex The index of the validator.
     *
     * @return withdrawAddress The withdraw address associated with the validator.
     */
    function getValidatorWithdrawAddress(
        uint _validatorIndex
    ) public view returns (address withdrawAddress) {
        withdrawAddress = beneficiaries[_validatorIndex].withdrawAddress;
    }

    /**
     * @dev Retrieves the information of a beneficiary for a specific validator index.
     * @param _validatorIndex The index of the validator.
     *
     * @return The beneficiary information.
     */
    function getBeneficiaryInfo(
        uint _validatorIndex
    ) public view returns (Beneficiary memory) {
        return beneficiaries[_validatorIndex];
    }
}