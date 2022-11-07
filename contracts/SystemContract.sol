//SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "./library/Initializable.sol";
import "./Params.sol";
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
    mapping(address => IValidator) public gValidatorsMap;  // mapping from validator address to validator contract.
    SortedLinkedList.List topValidators;             // A sorted linked list of all valid validators

    struct LazyPunishRecord {
        uint256 missedBlocksCounter;
        uint256 index;
        bool exist;
    }
    enum Operation {ShareOutBonus, UpdateValidators, LazyPunish, DecreaseMissingBlockCounter}
    mapping(uint256 => mapping(Operation => bool)) operationsDone;
    mapping(address => LazyPunishRecord) lazyPunishRecords;
    address[] public lazyPunishedSigners;
    mapping(bytes32 => bool) public doubleSignPunished;

    event LogDecreaseMissedBlocksCounter();
    event LogLazyPunishValidator(address indexed signer, uint256 time);
    event LogDoubleSignPunishValidator(address indexed signer, uint256 time);

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
        require(!val.isContract(), "E02");
        _;
    }

    modifier onlyMiner() {
        require(msg.sender == block.coinbase, "E04");
        _;
    }

    modifier onlyValidAddress(address addr) {
        require(addr != address(0), "E05");
        _;
    }
    
    modifier onlyValid100(uint256 rate) {
        require(rate <= RateDenominator, "E06");
        _;
    }

    modifier onlyGreaterZero(uint256 amount) {
        require(amount > 0, "E07");
        _;
    }

    modifier onlyOperateOnce(Operation operation) {
        require(!operationsDone[block.number][operation], "E06");
        operationsDone[block.number][operation] = true;
        _;
    }

    modifier onlyBlockEpoch() {
        require(block.number % gBlockEpoch == 0, "E17");
        _;
    }

    modifier onlyNotDoubleSignPunished(bytes32 punishHash) {
        require(!doubleSignPunished[punishHash], "E06");
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
        IValidator iVal = new Validator(signer, owner, rate, stake, acceptDelegation, StateReady, gBlockEpoch, gCommunityAddress);
        gValidatorsMap[signer] = iVal;
        topValidators.improveRanking(iVal);
        uint256 stocks = iVal.BuyStocks{value : stake}(owner);
        gTotalStake = gTotalStake.add(stake);
        gTotalStock = gTotalStock.add(stocks);
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
        require(msg.value >= gMinSelfStake, "E20");
        IValidator iVal = new Validator(signer, msg.sender, rate, msg.value, acceptDelegation, StateReady, gBlockEpoch, gCommunityAddress);
        gValidatorsMap[signer] = iVal;
        topValidators.improveRanking(iVal);
        uint256 stocks = iVal.BuyStocks{value : msg.value}(msg.sender);
        gTotalStake = gTotalStake.add(msg.value);
        gTotalStock = gTotalStock.add(stocks);
    }

    function ReactivateValidator(address signer)
    external
    payable
    onlyExistValidator(signer)
    onlyNotContract(signer)
    onlyInitialized {
        IValidator iVal = gValidatorsMap[signer];
        require(msg.sender == iVal.OwnerAddress(), "E22");
        require(iVal.SignerState() == StateExit || iVal.SignerState() == StateLazyPunish, "E55");
        if(iVal.SignerState() == StateLazyPunish) {
            require(msg.value >= gMinSelfStake, "E20");
        }
        if (msg.value > 0) {
            uint256 stocks = iVal.BuyStocks{value : msg.value}(msg.sender);
            gTotalStake = gTotalStake.add(msg.value);
            gTotalStock = gTotalStock.add(stocks);
        }
        iVal.SwitchState(StateReady);
        topValidators.improveRanking(iVal);
    }

    function BuyStocks(address signer)
        external
        payable
        onlyGreaterZero(msg.value)
        onlyExistValidator(signer)
        onlyNotContract(msg.sender) {
        IValidator iVal = gValidatorsMap[signer];
        require(iVal.SignerState() == StateReady, "E33");
        uint256 stocks = iVal.BuyStocks{value : msg.value}(msg.sender);
        if(iVal.SelfAssets(iVal.OwnerAddress()) >= gMinSelfStake) {
            topValidators.improveRanking(iVal);
        }
        gTotalStake = gTotalStake.add(msg.value);
        gTotalStock = gTotalStock.add(stocks);
    }

    function SellStocks(address signer, uint256 stocks)
        external
        onlyGreaterZero(stocks)
        onlyExistValidator(signer)
        onlyNotContract(msg.sender) {
        IValidator iVal = gValidatorsMap[signer];
        if (msg.sender == iVal.OwnerAddress()) {
            require(iVal.SignerState() != StateDoubleSignPunish, "E56");
        }
        uint256 stakes = iVal.SellStocks(msg.sender, stocks);
        if(iVal.SelfAssets(iVal.OwnerAddress()) < gMinSelfStake) {
            topValidators.removeRanking(iVal);
        } else {
            topValidators.lowerRanking(iVal);
        }
        gTotalStake = gTotalStake.sub(stakes);
        gTotalStock = gTotalStock.sub(stocks);
    }

    function Refund(address signer)
        external
        onlyExistValidator(signer) {
        address payable sender = payable(msg.sender);
        IValidator iVal = gValidatorsMap[signer];
        iVal.Refund(sender);
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
                    }
                    if(bonusValidator > 0) {
                        uint256 stocks = iVal.BuyStocks{value : bonusValidator}(iVal.OwnerAddress());
                        gTotalStock = gTotalStock.add(stocks);
                    }
                }
                if(cpFee > 0) {
                    sendValue(gCommunityAddress, cpFee);
                }
                gTotalStake = gTotalStake.add(bonusSingle);
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
    }

    function getActiveValidators() external view returns (address[] memory){
        return gActiveValidators;
    }

    function lazyPunish(address signer)
        external
        onlyLocal
        onlyExistValidator(signer)
        onlyOperateOnce(Operation.LazyPunish){
        if (!lazyPunishRecords[signer].exist) {
            lazyPunishRecords[signer].index = lazyPunishedSigners.length;
            lazyPunishedSigners.push(signer);
            lazyPunishRecords[signer].exist = true;
        }
        lazyPunishRecords[signer].missedBlocksCounter++;
        uint256 removeThreshold = gBlockEpoch / gActiveValidators.length;
        uint256 lazyPunishThreshold = removeThreshold / 2;
        IValidator iVal = gValidatorsMap[signer];
        uint256 finalValue = 0;
        uint256 ownerDiffStock = 0;
        if (lazyPunishRecords[signer].missedBlocksCounter % lazyPunishThreshold == 0) {
            (finalValue, ownerDiffStock) = iVal.LazyPunish(gMinSelfStake.div(4));
            gTotalStake = gTotalStake.sub(finalValue);
            gTotalStock = gTotalStock.sub(ownerDiffStock);
        } else if (lazyPunishRecords[signer].missedBlocksCounter % removeThreshold == 0){
            (finalValue, ownerDiffStock) = iVal.LazyPunish(gMinSelfStake.div(2));
            gTotalStake = gTotalStake.sub(finalValue);
            gTotalStock = gTotalStock.sub(ownerDiffStock);
            iVal.SwitchState(StateLazyPunish);
            topValidators.removeRanking(iVal);
            lazyPunishRecords[signer].missedBlocksCounter = 0;
        }
        emit LogLazyPunishValidator(signer, block.timestamp);
    }

    function decreaseMissedBlocksCounter()
        external
        onlyLocal
        onlyBlockEpoch
        onlyOperateOnce(Operation.DecreaseMissingBlockCounter){
        if (lazyPunishedSigners.length == 0) {
            return;
        }
        uint cnt = lazyPunishedSigners.length;
        for (uint256 i = cnt; i > 0; i--) {
            address signer = lazyPunishedSigners[i - 1];
            if (lazyPunishRecords[signer].missedBlocksCounter > DecreaseRate) {
                lazyPunishRecords[signer].missedBlocksCounter -= DecreaseRate;
            } else {
                if (i != cnt) {
                    // not the last one, swap
                    address tail = lazyPunishedSigners[cnt - 1];
                    lazyPunishedSigners[i - 1] = tail;
                    lazyPunishRecords[tail].index = i - 1;
                }
                // delete the last one
                lazyPunishedSigners.pop();
                lazyPunishRecords[signer].missedBlocksCounter = 0;
                lazyPunishRecords[signer].index = 0;
                lazyPunishRecords[signer].exist = false;
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
        (finalValue, ownerDiffStock) = iVal.LazyPunish(gMinSelfStake);
        gTotalStake = gTotalStake.sub(finalValue);
        gTotalStock = gTotalStock.sub(ownerDiffStock);
        iVal.SwitchState(StateDoubleSignPunish);
        topValidators.removeRanking(iVal);
        emit LogDoubleSignPunishValidator(signer, block.timestamp);
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
}
