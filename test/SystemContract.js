const hre = require("hardhat");
const {BigNumber} = require("ethers");
const {expect} = require("chai");
const ethers = hre.ethers;
const utils = require("./utils");

const MaxValidators = 21;
const BlockEpoch = 200;
const MinSelfStake = hre.ethers.utils.parseEther("10");
const CommunityAddress = "0x44fb52EB2bdDAf1c8b6D441e0b5DCa123A345292";
const ShareOutBonusPercent = 80;

let SystemContract;
let ValFactory;
let Signers
let totalStake = BigNumber.from(0);

describe("SystemContract test", function () {
  before(async function () {
    Signers = await ethers.getSigners();
    const SystemFactory = await ethers.getContractFactory("cache/solpp-generated-contracts/SystemContract.sol:SystemContract");
    SystemContract = await SystemFactory.deploy();
    ValFactory = await ethers.getContractFactory("cache/solpp-generated-contracts/Validator.sol:Validator");
  });

  it("1. Check initialize", async function () {
    const trx = await SystemContract.initialize(MaxValidators, BlockEpoch, MinSelfStake, CommunityAddress, ShareOutBonusPercent);
    let receipt = await trx.wait();
    expect(receipt.status).equal(1);

    expect(await SystemContract.gMaxValidators()).to.eq(MaxValidators);
    expect(await SystemContract.gBlockEpoch()).to.eq(BlockEpoch);
    expect(await SystemContract.gMinSelfStake()).to.eq(MinSelfStake);
    expect(await SystemContract.gCommunityAddress()).to.eq(CommunityAddress);
    expect(await SystemContract.gShareOutBonusPercent()).to.eq(ShareOutBonusPercent);
  });

  it("2. Check initValidator", async function () {
    const stake = utils.ethToWei(2000);
    totalStake = totalStake.add(stake);
    const trx = await SystemContract.initValidator(Signers[1].address, Signers[25+1].address, 50, stake);
    let receipt = await trx.wait();
    expect(receipt.status).equal(1);

    let valContractAddr = await SystemContract.gValsMap(Signers[1].address);
    let val = ValFactory.attach(valContractAddr);
    expect(await val.getRate()).equal(50);
    expect(await val.gManager()).equal(Signers[25+1].address);
    expect(await val.gValidator()).equal(Signers[1].address);
    expect(await val.gTotalStake()).equal(stake);
    expect(await val.gTotalStock()).equal(stake.mul(50));
  });

  it("3. Check registerValidator", async function () {
    await expect(SystemContract.registerValidator(Signers[1].address, Signers[1].address, 50)).to.be.revertedWith("E02");
    await expect(SystemContract.registerValidator(Signers[2].address, Signers[2].address, 50)).to.be.revertedWith("E20");
    await expect(SystemContract.registerValidator(Signers[2].address, Signers[2].address, 101)).to.be.revertedWith("E06");

    for(let i = 1; i < 25; i++) {
      const trx = await SystemContract.registerValidator(Signers[i+1].address, Signers[i+25+1].address, 50, {value:MinSelfStake});
      let receipt = await trx.wait();
      expect(receipt.status).equal(1);

      let valContractAddr = await SystemContract.gValsMap(Signers[i+1].address);
      let val = ValFactory.attach(valContractAddr);
      expect(await val.getRate()).equal(50);
      expect(await val.gManager()).equal(Signers[i+25+1].address);
      expect(await val.gValidator()).equal(Signers[i+1].address);
      expect(await val.gTotalStake()).equal(MinSelfStake);
      expect(await val.gTotalStock()).equal(MinSelfStake.mul(50));

      totalStake = totalStake.add(MinSelfStake);
    }
  });

  it("4. Check getTopValidators", async function () {
    const vals = await SystemContract.getTopValidators(25)
    expect(vals.length).equal(25);
    console.log(vals)
  });

  it("5. Check buyStocks", async function () {
    for(let i = 10; i >= 1; i--) {
      let holder = SystemContract.connect(Signers[50 + i])
      const trx = await holder.buyStocks(Signers[i+1].address, {value:MinSelfStake})
      let receipt = await trx.wait();
      expect(receipt.status).equal(1);
      let valContractAddr = await SystemContract.gValsMap(Signers[i+1].address);
      let val = ValFactory.attach(valContractAddr);
      expect(await val.gTotalStake()).equal(MinSelfStake.mul(2));
      expect(await val.gTotalStock()).equal(MinSelfStake.mul(50).mul(2));
      expect(await val.gStockMap(Signers[50 + i].address)).equal(MinSelfStake.mul(50));
      totalStake = totalStake.add(MinSelfStake);
    }
  });

  it("6. Check getTopValidators again", async function () {
    const vals = await SystemContract.getTopValidators(25)
    expect(vals.length).equal(25);
    console.log(vals)
  });

  it("7. Check gTotalStake", async function () {
    expect(await SystemContract.gTotalStake()).equal(totalStake);
  });

  it("8. Check sellStocks", async function () {
    for(let i = 10; i >= 1; i--) {
      let holder = SystemContract.connect(Signers[50 + i])
      const trx = await holder.sellStocks(Signers[i+1].address, MinSelfStake.mul(50))
      let receipt = await trx.wait();
      expect(receipt.status).equal(1);
      let valContractAddr = await SystemContract.gValsMap(Signers[i+1].address);
      let val = ValFactory.attach(valContractAddr);
      expect(await val.gTotalStake()).equal(MinSelfStake.mul(1));
      expect(await val.gTotalStock()).equal(MinSelfStake.mul(50));
      expect(await val.gStockMap(Signers[50 + i].address)).equal(MinSelfStake.mul(0));
      const refund = await val.gRefundMap(Signers[50 + i].address);
      expect(refund.refundPendingWei).equal(MinSelfStake);
      totalStake = totalStake.sub(MinSelfStake);
    }
  });

  it("9. Check gTotalStake", async function () {
    expect(await SystemContract.gTotalStake()).equal(totalStake);
  });

  it("10. Check refund", async function () {
    for(let i = 10; i >= 1; i--) {
      const oldBalance = await ethers.provider.getBalance(Signers[50 + i].address)
      let holder = SystemContract.connect(Signers[50 + i])
      const trx = await holder.refund(Signers[i+1].address)
      let receipt = await trx.wait();
      expect(receipt.status).equal(1);
      const gasUsed = receipt.gasUsed;
      const gasPrice = await ethers.provider.getGasPrice();
      let valContractAddr = await SystemContract.gValsMap(Signers[i+1].address);
      let val = ValFactory.attach(valContractAddr);
      const refund = await val.gRefundMap(Signers[50 + i].address);
      expect(refund.refundPendingWei).equal(0);
      const newBalance = await ethers.provider.getBalance(Signers[50 + i].address);
      expect(newBalance).to.eq(oldBalance.add(MinSelfStake).sub(gasUsed.mul(gasPrice)));
    }
  });
});
