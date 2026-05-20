var Reserve = artifacts.require("Reserve");
var SlashingInsuranceETH = artifacts.require("SlashingInsuranceETH");
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

    const [multiSig, validator_1, validator_2, validator_3, insurer_1, insurer_2, insurer_3, oracleCaller] = accounts;
    const premiumDeposit = web3.utils.toWei("0.5", "ether");
    const minimumSliDeposit = web3.utils.toWei("0.5", "ether");
    const minimumReserve = web3.utils.toWei("2", "ether");
    const maxClaim = web3.utils.toWei("16", "ether");
    const interest = web3.utils.toWei("10000", "gwei");
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

        const sliETHAddress = await this.reserve.getSlashingInsuranceETHAddress({from: multiSig})
        this.slashingInsuranceETH = await SlashingInsuranceETH.at(sliETHAddress);
    });

    it("provideInsurance mints sliETH for sender", async() => {
        await this.reserve.provideInsurance({from: insurer_1, value: premiumDeposit});
        const sliBalance = (await this.reserve.getSlashingInsuranceETHBalance(insurer_1)).toString();

        assert.strictEqual(sliBalance, premiumDeposit, "balance incorrect");
    });

    it("provideInsurance mints proportionally smaller amounts as reserve grows", async() => {
        await this.reserve.provideInsurance({from: insurer_1, value: premiumDeposit});

        this.aWethToken.mint(this.premiumGeneratorAaveV2.address, "1000000");

        await this.reserve.provideInsurance({from: insurer_2, value: premiumDeposit});
        const sliBalance_1 = (await this.reserve.getSlashingInsuranceETHBalance(insurer_1)).toString();
        assert.strictEqual(sliBalance_1, premiumDeposit, "balance incorrect");
        const sliBalance_2 = (await this.reserve.getSlashingInsuranceETHBalance(insurer_2)).toString();
        assert.strictEqual(sliBalance_2, "499999999999000000", "balance incorrect");
    });

    it("contract accepts eth send via transactions and mints sliETH for sender", async() => {
        //this.reserve.sendTransaction({to:this.reserve.address, from:insurer_1, value: "100000000000000"});
        await this.reserve.sendTransaction({to:this.reserve.address, from: multiSig, value: premiumDeposit});
        const sliBalance_1 = (await this.reserve.getSlashingInsuranceETHBalance(multiSig)).toString();
        assert.strictEqual(sliBalance_1, premiumDeposit, "balance 1 incorrect");
    });

    it("provideInsurance reverts when less than minimum is sent", async() =>{
        await expectRevert(
            this.reserve.sendTransaction({to:this.reserve.address, from: multiSig, value: "1000"}),
            "value must be greater than minimum"
        );
    });

    it("withdrawInsurance reverts when minimum reserve is not present", async() =>{
        await this.reserve.provideInsurance({from: insurer_1, value: TWO_ETH});
        await expectRevert(
            this.reserve.withdrawInsurance("1000", {from: insurer_1}),
            "reserve insufficient to withdraw insurance"
        );
    });

    it("withdrawInsurance reverts when user has insufficient sliETH", async() =>{
        await this.reserve.provideInsurance({from: insurer_1, value: minimumSliDeposit});
        await this.reserve.provideInsurance({from: insurer_2, value: largeDeposit});
        await expectRevert(
            this.reserve.withdrawInsurance(TWO_ETH, {from: insurer_1}),
            "Insufficient sliETH balance"
        );
    });

    it("withdrawInsurance reverts when sliETH requested exceeds total supply", async() =>{
        await this.reserve.provideInsurance({from: insurer_1, value: minimumSliDeposit});
        await this.reserve.provideInsurance({from: insurer_2, value: TWO_ETH});
        await expectRevert(
            this.reserve.withdrawInsurance(largeDeposit, {from: insurer_1}),
            "Panic: Arithmetic overflow"
        );
    });

    it("withdrawInsurance sends eth to withdraw address, lowers sliETH balance, and burns supply", async() => {
        await this.reserve.provideInsurance({from: insurer_1, value: largeDeposit});
        let b1 = await web3.eth.getBalance(insurer_1);
        const sliAmount = TWO_ETH;
        const sliBalance_1 = (await this.reserve.getSlashingInsuranceETHBalance(insurer_1)).toString();
        const sliTotal = (await  this.reserve.getSliETHTotalSupply()).toString();

        await this.reserve.withdrawInsurance(sliAmount, {from: insurer_1});
        let b2 = await web3.eth.getBalance(insurer_1);
        const sliBalance_2 = (await this.reserve.getSlashingInsuranceETHBalance(insurer_1)).toString();

        const sliBalanceCheck = (new BN(sliBalance_2).add(new BN(sliAmount))).toString();
        assert.strictEqual(sliBalance_1, sliBalanceCheck, "sliETH balance incorrect");

        const ethAdded = (new BN(b2).gt(new BN(b1)));
        assert.equal(ethAdded, true, "eth not withdrawn");

        const sliTotalCheck = ((await this.reserve.getSliETHTotalSupply()).add(new BN(sliAmount))).toString();
        assert.strictEqual(sliTotal, sliTotalCheck, "sliETH total incorrect");
    });


    it("applyForCoverage fails if there is an application pending", async() => {
        await this.reserve.provideInsurance({from: insurer_1, value: TWO_ETH});
        await this.reserve.applyForCoverage("210", {from: validator_1});

        await expectRevert(
            this.reserve.applyForCoverage("210", {from: validator_2}),
            "not eligible to apply"
        );
    });

    it("applyForCoverage user applies for slashing insurance", async() => {
        await this.reserve.provideInsurance({from: insurer_1, value: TWO_ETH});
        await this.reserve.applyForCoverage("210", {from: validator_1});
        const status = (await this.reserve.getBeneficiaryStatus("210")).toString();
        //AWAIT_ORACLE_ADD == 2
        assert.strictEqual("2", status, "The pool name did not return the correct address");
    })

    it("applyForCoverage user applies for slashing insurance having already been slashed", async() => {
        await this.reserve.provideInsurance({from: insurer_1, value: TWO_ETH});
        await this.reserve.applyForCoverage("210", {from: validator_1});
        await this.oracleMock.fulfillMultipleParameters("0x0", "210", 1, validator_1, 0, {from: oracleCaller});
        const status = (await this.reserve.getBeneficiaryStatus("210")).toString();
        //NOT_ACTIVE == 0
        assert.strictEqual("0", status, "The pool name did not return the correct address");
    });

    it("addBeneficiary reverts if user applies and does not deposit within 2 days and can re-apply", async() => {
        await this.reserve.provideInsurance({from: insurer_1, value: TWO_ETH});

        await this.reserve.applyForCoverage("210", {from: validator_1});
        await this.oracleMock.fulfillMultipleParameters("0x0", "210", 0, validator_1, 0, {from: oracleCaller});

        await time.increase(time.duration.weeks(1));

        await expectRevert(
            this.premiumGeneratorAaveV2.deposit("210", {from: validator_1, value: premiumDeposit}),
            "Outside apply window"
        );

        await this.reserve.applyForCoverage("210", {from: validator_1});
        await this.oracleMock.fulfillMultipleParameters("0x0", "210", 0, validator_1, 0, {from: oracleCaller});
        await this.premiumGeneratorAaveV2.deposit("210", {from: validator_1, value: premiumDeposit});
    })

    it(`applyForCoverage:
            - reverts for repeat or incorrect address
            - accepts application if match oracle
            - will revert if prev application approval
        addBeneficiary:
            - fails if validator index is not approved
            - fails if tx not from withdrawAddress
            - fails if sender is not a pool

        Premium deposit does not add to protocol balance
        Protocol balance increases as interest is earned
        Validator can withdraw and re-deposit

        `, async() => {
            //attempt to send from any address that is not the validator's withdrawAddress
            //should not be accepted
            await this.reserve.applyForCoverage("210", {from: validator_2});
            await this.oracleMock.fulfillMultipleParameters("0x0", "210", 0, validator_1, 0, {from: oracleCaller});
            let status = (await this.reserve.getBeneficiaryStatus("210")).toString();
            //NOT_ACTIVE == 0
            assert.strictEqual("0", status, "The application request was denied");

            //apply and will be accepted
            await this.reserve.applyForCoverage("210", {from: validator_1});
            await this.oracleMock.fulfillMultipleParameters("0x0", "210", 0, validator_1, 0, {from: oracleCaller});

            status = (await this.reserve.getBeneficiaryStatus("210")).toString();
            //AWAIT_ORACLE_ADD == 3
            assert.strictEqual("3", status, "The application request was denied");

            await expectRevert(
                this.reserve.applyForCoverage("210", {from: validator_1}),
                "not eligible to apply"
            );

            await this.reserve.provideInsurance({from: insurer_1, value: TWO_ETH});

           await expectRevert(
                this.premiumGeneratorAaveV2.deposit("2110", {from: validator_1, value: premiumDeposit}),
                "beneficiary is not approved"
            );

            await expectRevert(
                this.premiumGeneratorAaveV2.deposit("2110", {from: validator_1, value: premiumDeposit}),
                "beneficiary is not approved"
            );

            await expectRevert(
                this.premiumGeneratorAaveV2.deposit("210", {from: insurer_1, value: premiumDeposit}),
                "must send tx from validator withdrawAddress"
            );

            await expectRevert(
                this.premiumGeneratorAaveV2.deposit("210", {from: insurer_1, value: premiumDeposit}),
                "must send tx from validator withdrawAddress"
            );

            await expectRevert(
                this.reserve.addBeneficiary(validator_1, "210", {from: validator_1}),
                "sender is not pool"
            );
            const beforeDepBal = (await this.reserve.getProtocolBalance()).toString();
            await this.premiumGeneratorAaveV2.deposit("210", {from: validator_1, value: premiumDeposit});
            const afterDepBalBN = await this.reserve.getProtocolBalance();
            assert.strictEqual(beforeDepBal, afterDepBalBN.toString(), "The application request was denied");

            const afterInterestBalCheck = afterDepBalBN.add(new BN(interest)).toString();
            await this.poolMock.simulateInterest(interest, this.premiumGeneratorAaveV2.address, {from:multiSig});
            assert.strictEqual((await this.reserve.getProtocolBalance()).toString(), afterInterestBalCheck.toString());

            const valBal_1 = await web3.eth.getBalance(validator_1);

            await this.premiumGeneratorAaveV2.withdraw("210", {from: validator_1});

            const valBal_2 = await web3.eth.getBalance(validator_1);

            const ethAdded = (new BN(valBal_2).gt(new BN(valBal_1)));
            assert.equal(ethAdded, true, "eth not withdrawn");

            await expectRevert(
                this.premiumGeneratorAaveV2.deposit("210", {from: validator_1, value: premiumDeposit}),
                "beneficiary is not approved"
            );

            await this.reserve.applyForCoverage("210", {from: validator_1});
            await this.oracleMock.fulfillMultipleParameters("0x0", "210", 0, validator_1, 0, {from: oracleCaller});
            await this.premiumGeneratorAaveV2.deposit("210", {from: validator_1, value: premiumDeposit});
            await this.poolMock.simulateInterest(interest, this.premiumGeneratorAaveV2.address, {from:multiSig});
            await this.premiumGeneratorAaveV2.withdraw("210", {from: validator_1});
            const interestCheck = new BN(interest).add(new BN(interest)).toString();
            assert.strictEqual((await this.premiumGeneratorAaveV2.getUnclaimedInterest()).toString(), interestCheck, "interest not colculated correctly");

    });

    it("getMultiSig returns multiSig", async() => {
        const _multiSig = await this.reserve.multiSig({to:this.reserve.address, from: multiSig});
        assert.strictEqual(multiSig, _multiSig, "The pool name did not return the correct address");
    });
});