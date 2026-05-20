var Reserve = artifacts.require("Reserve");
var PoolAddressesProviderMock = artifacts.require("PoolAddressesProviderMock");
var PoolMock = artifacts.require("PoolMock");
var WethGatewayTest = artifacts.require("WethGatewayTest");
var OracleGateway = artifacts.require("OracleGateway");
var aTestToken = artifacts.require("aTestToken");
var TestToken = artifacts.require("TestToken");
var OracleMock = artifacts.require("OracleMock");
var PremiumGeneratorAaveV2 = artifacts.require("PremiumGeneratorAaveV2");
var LendingPoolAddressesProviderMock = artifacts.require("LendingPoolAddressesProviderMock");
var ProtocolDataProviderMock = artifacts.require("ProtocolDataProviderMock");
const { expectRevert, time } = require('@openzeppelin/test-helpers');

const chai = require("./setupchai.js");
const BN = web3.utils.BN;
const expect = chai.expect;

require("dotenv").config({path: "../.env"});

contract("Reserve", async (accounts) => {

    const [multiSig, oracleCaller, validator_1, validator_2, validator_3, validator_4, validator_5, insurer_1, insurer_2, insurer_3] = accounts;
    const premiumDeposit = web3.utils.toWei("0.5", "ether");
    const minimumSliDeposit = web3.utils.toWei("0.5", "ether");
    const minimumReserve = web3.utils.toWei("2", "ether");
    const maxClaim = web3.utils.toWei("4", "ether");
    const interest = web3.utils.toWei("1000000", "gwei");
    const largeDeposit = web3.utils.toWei("6", "ether");
    const TWO_ETH = web3.utils.toWei("2", "ether");
    const ONE_ETH = web3.utils.toWei("1", "ether");
    const HALF_ETH = web3.utils.toWei("0.5", "ether");

    beforeEach(async() => {
        this.wethToken = await TestToken.new();
        this.aWethToken = await aTestToken.new();
        this.poolMock = await PoolMock.new();
        await this.poolMock.setTestTokens(this.wethToken.address, this.aWethToken.address, {from: multiSig});

        this.poolAddressesProviderMock = await PoolAddressesProviderMock.new();
        await this.poolAddressesProviderMock.setPoolImpl(this.poolMock.address, {from: multiSig});

        this.lendingPoolAddressesProviderMock = await LendingPoolAddressesProviderMock.new(this.poolMock.address);
        this.protocolDataProviderMock = await ProtocolDataProviderMock.new(this.aWethToken.address);

        this.oracleMock = await OracleMock.new(multiSig);
        this.wethGateway = await WethGatewayTest.new();
        await this.wethGateway.setValues(this.wethToken.address, this.aWethToken.address, {from: multiSig});

        const wethGatewayAddr = this.wethGateway.address;

        this.oracleGateway = await OracleGateway.new(multiSig, this.oracleMock.address,  {from: multiSig})
        this.premiumGeneratorAaveV2 = await PremiumGeneratorAaveV2.new(this.lendingPoolAddressesProviderMock.address, this.protocolDataProviderMock.address, multiSig, wethGatewayAddr, premiumDeposit);
        this.reserve = await Reserve.new(multiSig,
                                        this.premiumGeneratorAaveV2.address,
                                        wethGatewayAddr,
                                        minimumSliDeposit,
                                        minimumReserve,
                                        maxClaim,
                                        this.oracleMock.address,
                                        this.oracleGateway.address);

        await this.oracleMock.setReserve(this.reserve.address, {from: multiSig});
        await this.premiumGeneratorAaveV2.setReserve(this.reserve.address, {from: multiSig});
        await this.oracleGateway.setReserve(this.reserve.address, {from: multiSig});

        await this.reserve.provideInsurance({from: insurer_1, value: largeDeposit});

        await this.reserve.applyForCoverage("210", {from: validator_1});
        await this.oracleMock.fulfillMultipleParameters("0x0", "210", 0, validator_1, 0, {from: oracleCaller});
        await this.premiumGeneratorAaveV2.deposit("210", {from: validator_1, value: premiumDeposit});

        await this.reserve.applyForCoverage("347", {from: validator_2});
        await this.oracleMock.fulfillMultipleParameters("0x0", "347", 0, validator_2, 0, {from: oracleCaller});
        await this.premiumGeneratorAaveV2.deposit("347", {from: validator_2, value: premiumDeposit});

        await this.reserve.applyForCoverage("55", {from: validator_3});
        await this.oracleMock.fulfillMultipleParameters("0x0", "55", 0, validator_3, 0, {from: oracleCaller});
        await this.premiumGeneratorAaveV2.deposit("55", {from: validator_3, value: premiumDeposit});

        await this.reserve.applyForCoverage("4807", {from: validator_4});
        await this.oracleMock.fulfillMultipleParameters("0x0", "4807", 0, validator_4, 0, {from: oracleCaller});
        await this.premiumGeneratorAaveV2.deposit("4807", {from: validator_4, value: premiumDeposit});

        await this.reserve.applyForCoverage("100000", {from: validator_5});
        await this.oracleMock.fulfillMultipleParameters("0x0", "100000", 0, validator_5, 0, {from: oracleCaller});
        await this.premiumGeneratorAaveV2.deposit("100000", {from: validator_5, value: premiumDeposit});

        await this.reserve.applyForCoverage("100", {from: validator_5});
        await this.oracleMock.fulfillMultipleParameters("0x0", "100", 0, validator_5, 0, {from: oracleCaller});
        await this.premiumGeneratorAaveV2.deposit("100", {from: validator_5, value: premiumDeposit});

        await this.poolMock.simulateInterest(interest, this.premiumGeneratorAaveV2.address, {from:multiSig});

        await this.reserve.provideInsurance({from: insurer_2, value: largeDeposit});
        await this.reserve.provideInsurance({from: insurer_3, value: ONE_ETH});

    });

    it("getBeneficiaryInfo returns Beneficiary details", async() => {
        const ids = (await this.reserve.getDepositorValidatorIds(validator_1)).toString();
        assert.equal(ids, "210", "validator ids incorrect");
        const info = (await this.reserve.getBeneficiaryInfo(ids)).toString();
        assert.equal(info[0], "1", "beneficiary info is incorrect");
    });

    it("getDepositorValidatorIds returns all validatorIds associated with withdrawAddress", async() => {
        const ids = (await this.reserve.getDepositorValidatorIds(validator_5)).toString();
        assert.equal(ids, "100000,100", "validator ids incorrect");
    });

    it("conversion rate on sli improves as contracts accrue interest", async() => {
        const before = await this.reserve.getSliETHConversion();

        await this.poolMock.simulateInterest(largeDeposit, this.premiumGeneratorAaveV2.address, {from:multiSig});

        const after = await this.reserve.getSliETHConversion();

        const ethAdded = (new BN(after).gt(new BN(before)));
        assert.equal(ethAdded, true, "conversion rate unchanged");
    });

    it("makeClaim reverts if tx not from withdrawAddress", async() => {

        await expectRevert(
            this.reserve.makeClaim("210", {from: validator_5}),
            "withdrawAddress does not match"
        );

    });

    it("makeClaim reverts if claim already pending", async() => {
        await this.reserve.makeClaim("210", {from: validator_1});
        await expectRevert(
            this.reserve.makeClaim("210", {from: validator_1}),
            "beneficiary not active"
        );
    });

    it("makeClaim changes status of beneficiary to AWAIT_ORACLE_CLAIM", async() => {
        await this.reserve.makeClaim("210", {from: validator_1});
        const status = (await this.reserve.getBeneficiaryStatus("210")).toString();
        //AWAIT_ORACLE_CLAIM == 4
        assert.strictEqual("4", status, "The pool name did not return the correct address");
    });

    it("oracleResponse functions returns if beneficiary status is not AWAIT_ORACLE_CLAIM", async() => {
        await this.oracleMock.fulfillMultipleParameters("0x0", "210", 1, validator_1, ONE_ETH, {from: oracleCaller});

        const status = (await this.reserve.getBeneficiaryStatus("210")).toString();
        //ACTIVE == 1
        assert.strictEqual("1", status, "The pool name did not return the correct address");
    });
    it("oracleResponse reverts if oracle is not the msg.sender", async() => {
        await this.reserve.makeClaim("210", {from: validator_1});
        await expectRevert(
            this.reserve.oracleResponse("210", 1, validator_1, ONE_ETH, {from: validator_1}),
            "not the oracle"
        );
    });
    it("oracleResponse sets status to ACTIVE if not slashed", async() => {
        await this.reserve.makeClaim("210", {from: validator_1});
        await this.oracleMock.fulfillMultipleParameters("0x0", "210", 0, validator_1, ONE_ETH, {from: oracleCaller});

        //status set to ACTIVE
        const status = (await this.reserve.getBeneficiaryStatus("210")).toString();
        //ACTIVE == 1
        assert.strictEqual("1", status, "The pool name did not return the correct address");
    });
    it("oracleResponse status to ACTIVE if loss == 0, happens if slashed but waiting withdrawal", async() => {
        await this.reserve.makeClaim("210", {from: validator_1});
        await this.oracleMock.fulfillMultipleParameters("0x0", "210", 0, validator_1, '0', {from: oracleCaller});

        //status set to ACTIVE
        const status = (await this.reserve.getBeneficiaryStatus("210")).toString();
        //ACTIVE == 1
        assert.strictEqual("1", status, "The pool name did not return the correct address");
    });

    it("oracleResponse status to CLAIM_PAUSED if loss > maxClaim", async() => {
        await this.reserve.makeClaim("210", {from: validator_1});
        await this.oracleMock.fulfillMultipleParameters("0x0", "210", 1, validator_1, largeDeposit, {from: oracleCaller});

        const status = (await this.reserve.getBeneficiaryStatus("210")).toString();
        //CLAIM_PAUSED == 7
        assert.strictEqual("7", status, "The pool name did not return the correct address");
    });

    it("payClaim reverts if timeout not expired", async() => {
        await this.reserve.makeClaim("210", {from: validator_1});
        await this.oracleMock.fulfillMultipleParameters("0x0", "210", 1, validator_1, ONE_ETH, {from: oracleCaller});
        let status = (await this.reserve.getBeneficiaryStatus("210")).toString();
        //CLAIM_WAIT_PERIOD == 5
        assert.strictEqual("5", status, "The pool name did not return the correct address");

        await expectRevert(
            this.reserve.payClaim("210", {from: validator_1}),
            "Cannot withdraw claim until timeout passed"
        );

    });

    it("payClaim reverts if no callback from oracle (not in CLAIM_PENDING)", async() => {
        await this.reserve.makeClaim("210", {from: validator_1});
        await expectRevert(
            this.reserve.payClaim("210", {from: validator_1}),
            "no claim pending"
        );

    });

    it("oracleResponse changes status to CLAIM_WAIT_PERIOD, payClaim makes payout to validator", async() => {
        await this.reserve.makeClaim("210", {from: validator_1});
        await this.oracleMock.fulfillMultipleParameters("0x0", "210", 1, validator_1, ONE_ETH, {from: oracleCaller});
        let status = (await this.reserve.getBeneficiaryStatus("210")).toString();
        //CLAIM_WAIT_PERIOD == 5
        assert.strictEqual("5", status, "The pool name did not return the correct address");

        //console.log((await time.latest()).toString());

        await time.increase(time.duration.weeks(3));

        const valBal_1 = await web3.eth.getBalance(validator_1);
        await this.reserve.payClaim("210", {from: validator_4});
        const valBal_2 = await web3.eth.getBalance(validator_1);

        let diff = new BN(valBal_2).sub(new BN(valBal_1));
        let payout = new BN(ONE_ETH).add(new BN(premiumDeposit));
        assert.strictEqual(diff.toString(), payout.toString(), "validator not paid claim");

        status = (await this.reserve.getBeneficiaryStatus("210")).toString();
        //CLOSED == 6
        assert.strictEqual("6", status, "The pool name did not return the correct address");
    });

    it("pauseClaim, unpauseClaim, resetClaim, and denyClaim can be called by only multisig", async() => {
        await this.reserve.makeClaim("210", {from: validator_1});
        await this.oracleMock.fulfillMultipleParameters("0x0", "210", 1, validator_1, ONE_ETH, {from: oracleCaller});
        await this.reserve.pauseClaim("210", {from: multiSig});
        let status = (await this.reserve.getBeneficiaryStatus("210")).toString();
        //CLAIM_PAUSED == 7
        assert.strictEqual("7", status, "The pool name did not return the correct address");

        //await this.reserve.unpauseClaim("210", {from: multiSig});

        await expectRevert(
            this.reserve.payClaim("210", {from: validator_1}),
            "no claim pending"
        );

        await this.reserve.unpauseClaim("210", {from: multiSig});
        status = (await this.reserve.getBeneficiaryStatus("210")).toString();
        //CLAIM_WAIT_PERIOD == 5
        assert.strictEqual("5", status, "The pool name did not return the correct address");

        await expectRevert(
            this.reserve.pauseClaim("210", {from: validator_4}),
            "not the multiSig"
        );

        await expectRevert(
            this.reserve.unpauseClaim("210", {from: multiSig}),
            "no claim paused"
        );

        await this.reserve.pauseClaim("210", {from: multiSig});

        await expectRevert(
            this.reserve.unpauseClaim("210", {from: validator_4}),
            "not the multiSig"
        );

        await expectRevert(
            this.reserve.denyClaim("210", {from: validator_4}),
            "not the multiSig"
        );

        await this.reserve.denyClaim("210", {from: multiSig});
        status = (await this.reserve.getBeneficiaryStatus("210")).toString();
        //CLOSED == 6
        assert.strictEqual("6", status, "The pool name did not return the correct address");

        await expectRevert(
            this.reserve.resetClaim("210", {from: validator_4}),
            "not the multiSig"
        );

        await this.reserve.resetClaim("210", {from: multiSig});
        status = (await this.reserve.getBeneficiaryStatus("210")).toString();
        //ACTIVE == 1
        assert.strictEqual("1", status, "The pool name did not return the correct address");
    });

});