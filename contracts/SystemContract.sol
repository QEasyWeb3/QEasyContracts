//SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "./library/Initializable.sol";
import "./Validator.sol";
import "./interfaces/IValidator.sol";
import "./library/SortedList.sol";

contract SystemContract is Initializable, SafeSend {
    using SafeMath for uint256;
    using Address for address;
    using SortedLinkedList for SortedLinkedList.List;

    uint256 public constant DecreaseRate = 4;        // the allowable amount of missing blocks in one epoch for each validator


    uint256 public gBlockEpoch;                      // The cycle in which the corresponding update is performed
    uint256 public gMinSelfStake;                    // Become the verifier's own minimum stake
    address payable public gCommunityAddress;        //
    address public gAdminAddress;
    uint8 public gShareOutBonusPercent;              //

    uint256 public gTotalStake;                      // Total stake amount of the whole network
    uint256 public gTotalStock;                      // Total stock amount of the whole network
    address[] public gActiveValidators;              // Validator address of the outgoing block in the current epoch
    address[] public gAllValidatorAddresses;
    mapping(address => IValidator) public gValidatorsMap;  // mapping from validator address to validator contract.
    SortedLinkedList.List topValidators;             // A sorted linked list of all valid validators

    struct LazyPunishRecord {
        uint256 missedBlocksCounter;
        uint256 index;
        bool exist;
    }
    enum Operation {ShareOutBonus, UpdateValidators, LazyPunish, DecreaseMissingBlockCounter}
    mapping(uint256 => mapping(Operation => bool)) operationsDone;
    mapping(address => LazyPunishRecord) gLazyPunishRecords;
    address[] public gLazyPunishedSigners;
    mapping(bytes32 => bool) public doubleSignPunished;

    event LogRegisterValidator(address indexed signer, uint256 rate, bool acceptDelegation);
    event LogReactivateValidator(address indexed signer);
    event LogBuyStocks(address indexed holder, address indexed signer, uint256 amount, uint256 stocks);
    event LogSellStocks(address indexed holder, address indexed signer, uint256 stocks, uint256 amount);
    event LogRefund(address indexed signer, uint256 amount);
    event LogDistributeBlockTotalFee(uint256 indexed blockNumber, uint256 amount);
    event LogCommunityAddressAddFee(uint256 indexed blockNumber, uint256 amount);
    event LogAddBonus(address indexed signer, uint256 amount);
    event LogUpdateActiveValidatorSet();
    event LogDecreaseMissedBlocksCounter();
    event LogDoLazyPunishLast(address indexed signer, uint256 amount, uint256 stocks);
    event LogDoLazyPunishOnce(address indexed signer, uint256 amount, uint256 stocks);
    event LogLazyPunishValidator(address indexed signer, uint256 indexed blockNumber);
    event LogDoubleSignPunishValidator(address indexed signer, uint256 indexed blockNumber);

    modifier onlyLocal() {
        require(msg.sender == address(0x0000000000000000000000000000000000000000), "E00");
        _;
    }

    modifier onlyGenesisBlock() {
        require(block.number == 0, "E01");
        _;
    }

    modifier onlyNotExistValidator(address val) {
        require(gValidatorsMap[val] == IValidator(address(0)), "E02");
        _;
    }

    modifier onlyExistValidator(address val) {
        require(gValidatorsMap[val] != IValidator(address(0)), "E03");
        _;
    }

    modifier onlyNotContract(address val) {
        require(!val.isContract(), "E04");
        _;
    }

    modifier onlyMiner() {
        require(msg.sender == block.coinbase, "E05");
        _;
    }

    modifier onlyValidAddress(address addr) {
        require(addr != address(0), "E06");
        _;
    }
    
    modifier onlyValid100(uint256 rate) {
        require(rate <= RateDenominator, "E07");
        _;
    }

    modifier onlyGreaterZero(uint256 amount) {
        require(amount > 0, "E08");
        _;
    }

    modifier onlyOperateOnce(Operation operation) {
        require(!operationsDone[block.number][operation], "E09");
        operationsDone[block.number][operation] = true;
        _;
    }

    modifier onlyBlockEpoch() {
        require(block.number % gBlockEpoch == 0, "E10");
        _;
    }

    modifier onlyNotDoubleSignPunished(bytes32 punishHash) {
        require(!doubleSignPunished[punishHash], "E11");
        _;
    }

    function initialize(address adminAddress, uint256 epoch, uint256 minSelfStake,
        address payable communityAddress, uint8 shareOutBonusPercent)
        external
        onlyValidAddress(adminAddress)
        onlyGreaterZero(epoch)
        onlyValidAddress(communityAddress)
        onlyValid100(shareOutBonusPercent)
        initializer {
        gAdminAddress = adminAddress;
        gBlockEpoch = epoch;
        gMinSelfStake = minSelfStake;
        gCommunityAddress = communityAddress;
        gShareOutBonusPercent = shareOutBonusPercent;
    }

    function initValidator(address signer, address owner, uint256 rate, uint256 stake, bool acceptDelegation)
        external
        onlyNotExistValidator(signer)
        onlyValidAddress(signer)
        onlyValidAddress(owner)
        onlyValid100(rate)
        onlyGreaterZero(stake)
        onlyGenesisBlock
        onlyInitialized {
        IValidator iVal = new Validator(signer, owner, rate, acceptDelegation, StateReady, gBlockEpoch, gCommunityAddress);
        gValidatorsMap[signer] = iVal;
        uint256 stocks = iVal.BuyStocks{value : stake}(owner);
        gTotalStake = gTotalStake.add(stake);
        gTotalStock = gTotalStock.add(stocks);
        topValidators.improveRanking(iVal);
        gAllValidatorAddresses.push(signer);
    }

    function RegisterValidator(address signer, uint256 rate, bool acceptDelegation)
        external
        payable
        onlyNotExistValidator(signer)
        onlyValidAddress(signer)
        onlyValidAddress(msg.sender)
        onlyNotContract(signer)
        onlyNotContract(msg.sender)
        onlyValid100(rate)
        onlyInitialized {
        require(msg.value >= gMinSelfStake, "E12");
        IValidator iVal = new Validator(signer, msg.sender, rate, acceptDelegation, StateReady, gBlockEpoch, gCommunityAddress);
        gValidatorsMap[signer] = iVal;
        uint256 stocks = iVal.BuyStocks{value : msg.value}(msg.sender);
        gTotalStake = gTotalStake.add(msg.value);
        gTotalStock = gTotalStock.add(stocks);
        topValidators.improveRanking(iVal);
        gAllValidatorAddresses.push(signer);
        emit LogRegisterValidator(signer, rate, acceptDelegation);
    }

    function ReactivateValidator(address signer)
    external
    payable
    onlyExistValidator(signer)
    onlyNotContract(signer)
    onlyInitialized {
        IValidator iVal = gValidatorsMap[signer];
        require(msg.sender == iVal.OwnerAddress(), "E13");
        require(iVal.SignerState() == StateExit || iVal.SignerState() == StateLazyPunish, "E14");
        if(iVal.SignerState() == StateLazyPunish) {
            require(msg.value >= gMinSelfStake, "E15");
        }
        if (msg.value > 0) {
            uint256 stocks = iVal.BuyStocks{value : msg.value}(msg.sender);
            gTotalStake = gTotalStake.add(msg.value);
            gTotalStock = gTotalStock.add(stocks);
        }
        iVal.SwitchState(StateReady);
        topValidators.improveRanking(iVal);
        emit LogReactivateValidator(signer);
    }

    function BuyStocks(address signer)
        external
        payable
        onlyGreaterZero(msg.value)
        onlyExistValidator(signer)
        onlyNotContract(msg.sender) {
        IValidator iVal = gValidatorsMap[signer];
        require(iVal.SignerState() == StateReady, "E16");
        uint256 stocks = iVal.BuyStocks{value : msg.value}(msg.sender);
        if(iVal.SelfAssets(iVal.OwnerAddress()) >= gMinSelfStake) {
            topValidators.improveRanking(iVal);
        }
        gTotalStake = gTotalStake.add(msg.value);
        gTotalStock = gTotalStock.add(stocks);
        emit LogBuyStocks(msg.sender, signer, msg.value, stocks);
    }

    function SellStocks(address signer, uint256 stocks)
        external
        onlyGreaterZero(stocks)
        onlyExistValidator(signer)
        onlyNotContract(msg.sender) {
        IValidator iVal = gValidatorsMap[signer];
        if (msg.sender == iVal.OwnerAddress()) {
            require(iVal.SignerState() != StateDoubleSignPunish, "E17");
        }
        uint256 stakes = iVal.SellStocks(msg.sender, stocks);
        if(iVal.SelfAssets(iVal.OwnerAddress()) < gMinSelfStake) {
            topValidators.removeRanking(iVal);
        } else {
            topValidators.lowerRanking(iVal);
        }
        gTotalStake = gTotalStake.sub(stakes);
        gTotalStock = gTotalStock.sub(stocks);
        emit LogSellStocks(msg.sender, signer, stocks, stakes);
    }

    function Refund(address signer)
        external
        onlyExistValidator(signer) {
        address payable sender = payable(msg.sender);
        IValidator iVal = gValidatorsMap[signer];
        uint256 amount = iVal.Refund(sender);
        emit LogRefund(signer, amount);
    }

    function distributeBlockFee()
        external
        payable
        onlyLocal
        onlyOperateOnce(Operation.ShareOutBonus) {
        if (msg.value > 0) {
            uint cnt = gActiveValidators.length;
            if (cnt > 0) {
                uint256 amount = msg.value;
                uint bonusSingle = amount.mul(gShareOutBonusPercent).div(RateDenominator).div(cnt);
                uint cpFee = amount - (bonusSingle * cnt);
                for (uint i = 0; i < cnt; i++) {
                    address val = gActiveValidators[i];
                    IValidator iVal = gValidatorsMap[val];
                    uint256 rate = iVal.SignerRate();
                    uint256 bonusInvestor = bonusSingle.mul(rate).div(RateDenominator);
                    uint256 bonusValidator = bonusSingle - bonusInvestor;
                    if(bonusInvestor > 0) {
                        iVal.AddBonus{value : bonusInvestor}();
                        emit LogAddBonus(val, bonusInvestor);
                    }
                    if(bonusValidator > 0) {
                        uint256 stocks = iVal.BuyStocks{value : bonusValidator}(iVal.OwnerAddress());
                        gTotalStock = gTotalStock.add(stocks);
                        emit LogBuyStocks(iVal.OwnerAddress(), val, bonusValidator, stocks);
                    }
                }
                if(cpFee > 0) {
                    sendValue(gCommunityAddress, cpFee);
                    emit LogCommunityAddressAddFee(block.number, cpFee);
                }
                gTotalStake = gTotalStake.add(bonusSingle);
                emit LogDistributeBlockTotalFee(block.number, amount);
            }
        }
    }

    function getTopValidators(uint8 count) external view returns (address[] memory) {
        // set max limit: min(_count, list.length)
        if (count > topValidators.length) {
            count = topValidators.length;
        }
        address[] memory _topValidators = new address[](count);
        IValidator cur = topValidators.head;
        for (uint8 i = 0; i < count; i++) {
            _topValidators[i] = cur.SignerAddress();
            cur = topValidators.next[cur];
        }
        return _topValidators;
    }

    function updateActiveValidatorSet(address[] memory newSet)
        external
        onlyLocal
        onlyOperateOnce(Operation.UpdateValidators)
        onlyBlockEpoch {
        require(newSet.length > 0, "E18");
        gActiveValidators = newSet;
        emit LogUpdateActiveValidatorSet();
    }

    function getActiveValidators() external view returns (address[] memory){
        return gActiveValidators;
    }

    function isActiveValidator(address who) public view returns (bool) {
        for (uint256 i = 0; i < gActiveValidators.length; i++) {
            if (gActiveValidators[i] == who) {
                return true;
            }
        }
        return false;
    }

    function lazyPunish(address signer)
        external
        onlyLocal
        onlyExistValidator(signer)
        onlyOperateOnce(Operation.LazyPunish){
        if (!gLazyPunishRecords[signer].exist) {
            gLazyPunishRecords[signer].index = gLazyPunishedSigners.length;
            gLazyPunishedSigners.push(signer);
            gLazyPunishRecords[signer].exist = true;
        }
        IValidator iVal = gValidatorsMap[signer];
        if (iVal.SignerState() == StateLazyPunish) {
            return;
        }
        gLazyPunishRecords[signer].missedBlocksCounter++;
        uint256 removeThreshold = (gBlockEpoch / gActiveValidators.length / 4).mul(4);
        uint256 lazyPunishThreshold = removeThreshold / 2;
        uint256 finalValue = 0;
        uint256 ownerDiffStock = 0;
        if (gLazyPunishRecords[signer].missedBlocksCounter % removeThreshold == 0){
            (finalValue, ownerDiffStock) = iVal.DoPunish(gMinSelfStake.div(5));
            gTotalStake = gTotalStake.sub(finalValue);
            gTotalStock = gTotalStock.sub(ownerDiffStock);
            iVal.SwitchState(StateLazyPunish);
            topValidators.removeRanking(iVal);
            gLazyPunishRecords[signer].missedBlocksCounter = 0;
            emit LogDoLazyPunishLast(signer, finalValue, ownerDiffStock);
        } else if (gLazyPunishRecords[signer].missedBlocksCounter % lazyPunishThreshold == 0) {
            (finalValue, ownerDiffStock) = iVal.DoPunish(gMinSelfStake.div(10));
            gTotalStake = gTotalStake.sub(finalValue);
            gTotalStock = gTotalStock.sub(ownerDiffStock);
            topValidators.lowerRanking(iVal);
            emit LogDoLazyPunishOnce(signer, finalValue, ownerDiffStock);
        }
        emit LogLazyPunishValidator(signer, block.number);
    }

    function decreaseMissedBlocksCounter()
        external
        onlyLocal
        onlyBlockEpoch
        onlyOperateOnce(Operation.DecreaseMissingBlockCounter){
        if (gLazyPunishedSigners.length == 0) {
            return;
        }
        uint cnt = gLazyPunishedSigners.length;
        for (uint256 i = cnt; i > 0; i--) {
            address signer = gLazyPunishedSigners[i - 1];
            if (gLazyPunishRecords[signer].missedBlocksCounter > DecreaseRate) {
                gLazyPunishRecords[signer].missedBlocksCounter -= DecreaseRate;
            } else {
                if (i != cnt) {
                    // not the last one, swap
                    address tail = gLazyPunishedSigners[cnt - 1];
                    gLazyPunishedSigners[i - 1] = tail;
                    gLazyPunishRecords[tail].index = i - 1;
                }
                // delete the last one
                gLazyPunishedSigners.pop();
                gLazyPunishRecords[signer].missedBlocksCounter = 0;
                gLazyPunishRecords[signer].index = 0;
                gLazyPunishRecords[signer].exist = false;
                cnt -= 1;
            }
        }
        emit LogDecreaseMissedBlocksCounter();
    }

    function doubleSignPunish(bytes32 punishHash, address signer)
        external
        onlyLocal
        onlyExistValidator(signer)
        onlyNotDoubleSignPunished(punishHash) {
        doubleSignPunished[punishHash] = true;
        IValidator iVal = gValidatorsMap[signer];
        uint256 finalValue = 0;
        uint256 ownerDiffStock = 0;
        (finalValue, ownerDiffStock) = iVal.DoPunish(gMinSelfStake);
        gTotalStake = gTotalStake.sub(finalValue);
        gTotalStock = gTotalStock.sub(ownerDiffStock);
        iVal.SwitchState(StateDoubleSignPunish);
        topValidators.removeRanking(iVal);
        emit LogDoubleSignPunishValidator(signer, block.number);
    }

    function isDoubleSignPunished(bytes32 punishHash) public view returns (bool) {
        return doubleSignPunished[punishHash];
    }

    function TotalAssets(address signer, address holder) public view returns (uint256) {
        IValidator iVal = gValidatorsMap[signer];
        return iVal.SelfAssets(holder);
    }

    function TotalStocks(address signer, address holder) public view returns (uint256) {
        IValidator iVal = gValidatorsMap[signer];
        return iVal.SelfStocks(holder);
    }

    function TotalStake(address signer) public view returns (uint256) {
        IValidator iVal = gValidatorsMap[signer];
        return iVal.TotalStake();
    }

    function TotalStock(address signer) public view returns (uint256) {
        IValidator iVal = gValidatorsMap[signer];
        return iVal.TotalStock();
    }

    function SignerRate(address signer) public view returns (uint256) {
        IValidator iVal = gValidatorsMap[signer];
        return iVal.SignerRate();
    }

    function OwnerAddress(address signer) public view returns (address) {
        IValidator iVal = gValidatorsMap[signer];
        return iVal.OwnerAddress();
    }

    function SignerState(address signer) public view returns (uint8) {
        IValidator iVal = gValidatorsMap[signer];
        return iVal.SignerState();
    }

    function IsAcceptDelegation(address signer) public view returns (bool) {
        IValidator iVal = gValidatorsMap[signer];
        return iVal.IsAcceptDelegation();
    }

    function IsHolderExist(address signer, address holder) public view returns (bool) {
        IValidator iVal = gValidatorsMap[signer];
        return iVal.IsHolderExist(holder);
    }

    function HolderAddressesLength(address signer) public view returns (uint256) {
        IValidator iVal = gValidatorsMap[signer];
        return iVal.HolderAddressesLength();
    }

    function HolderAddresses(address signer, uint256 startIndex, uint256 count) public view returns (address[] memory) {
        IValidator iVal = gValidatorsMap[signer];
        return iVal.HolderAddresses(startIndex, count);
    }

    function AllValidatorsLength() external view returns (uint256){
        return gAllValidatorAddresses.length;
    }

    function LazyPunishedSignersLength() public view returns (uint256) {
        return gLazyPunishedSigners.length;
    }

    function LazyPunishMissedBlocksCounter(address signer) public view returns (uint256) {
        return gLazyPunishRecords[signer].missedBlocksCounter;
    }

    function RefundPendingWei(address signer, address holder) public view returns (uint256) {
        IValidator iVal = gValidatorsMap[signer];
        return iVal.RefundPendingWei(holder);
    }
}
