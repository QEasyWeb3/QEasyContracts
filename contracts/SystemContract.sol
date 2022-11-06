//SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "./library/Initializable.sol";
import "./Params.sol";
import "./Validator.sol";
import "./interfaces/IValidator.sol";
import "./library/SortedList.sol";

contract SystemContract is Initializable, Params, SafeSend {
    using SafeMath for uint256;
    using Address for address;
    using SortedLinkedList for SortedLinkedList.List;

    uint256 public constant RateDenominator = 100;   // rate denominator
    uint256 public gBlockEpoch;                      // The cycle in which the corresponding update is performed
    uint256 public gMinSelfStake;                    // Become the verifier's own minimum stake
    address payable public gCommunityAddress;        //
    address public gAdminAddress;
    uint8 public gShareOutBonusPercent;              //

    uint256 public gTotalStake;                      // Total stake amount of the whole network
    address[] public gActiveValidators;              // Validator address of the outgoing block in the current epoch
    mapping(address => IValidator) public gValidatorsMap;  // mapping from validator address to validator contract.
    SortedLinkedList.List topValidators;             // A sorted linked list of all valid validators

    enum Operation {ShareOutBonus, UpdateValidators, LazyPunish, DecreaseMissingBlockCounter}
    mapping(uint256 => mapping(Operation => bool)) operationsDone;
    mapping(bytes32 => bool) public doubleSignPunished;

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

    function initValidator(address singer, address owner, uint256 rate, uint256 stake, bool acceptDelegation)
        external
        onlyNotExistValidator(singer)
        onlyValidAddress(singer)
        onlyValidAddress(owner)
        onlyValid100(rate)
        onlyGreaterZero(stake)
        onlyGenesisBlock
        onlyInitialized {
        IValidator iVal = new Validator(singer, owner, rate, stake, acceptDelegation, StateReady, gBlockEpoch);
        gValidatorsMap[singer] = iVal;
        topValidators.improveRanking(iVal);
        iVal.BuyStocks{value : stake}(owner);
        gTotalStake = gTotalStake.add(stake);
    }

    function RegisterValidator(address singer, uint256 rate, bool acceptDelegation)
        external
        payable
        onlyNotExistValidator(singer)
        onlyValidAddress(singer)
        onlyValidAddress(msg.sender)
        onlyNotContract(singer)
        onlyNotContract(msg.sender)
        onlyValid100(rate)
        onlyInitialized {
        require(msg.value >= gMinSelfStake, "E20");
        IValidator iVal = new Validator(singer, msg.sender, rate, msg.value, acceptDelegation, StateReady, gBlockEpoch);
        gValidatorsMap[singer] = iVal;
        topValidators.improveRanking(iVal);
        iVal.BuyStocks{value : msg.value}(msg.sender);
        gTotalStake = gTotalStake.add(msg.value);
    }

    function BuyStocks(address singer)
        external
        payable
        onlyGreaterZero(msg.value)
        onlyExistValidator(singer)
        onlyNotContract(msg.sender) {
        IValidator iVal = gValidatorsMap[singer];
        iVal.BuyStocks{value : msg.value}(msg.sender);
        if(iVal.SelfAssets(iVal.OwnerAddress()) >= gMinSelfStake) {
            topValidators.improveRanking(iVal);
        }
        gTotalStake = gTotalStake.add(msg.value);
    }

    function SellStocks(address singer, uint256 stocks)
        external
        onlyGreaterZero(stocks)
        onlyExistValidator(singer)
        onlyNotContract(msg.sender) {
        IValidator iVal = gValidatorsMap[singer];
        uint256 stakes = iVal.SellStocks(msg.sender, stocks);
        if(iVal.SelfAssets(iVal.OwnerAddress()) < gMinSelfStake) {
            topValidators.removeRanking(iVal);
        } else {
            topValidators.lowerRanking(iVal);
        }
        gTotalStake = gTotalStake.sub(stakes);
    }

    function Refund(address singer)
        external
        onlyExistValidator(singer) {
        address payable sender = payable(msg.sender);
        IValidator iVal = gValidatorsMap[singer];
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
                    uint256 rate = iVal.SingerRate();
                    uint256 bonusInvestor = bonusSingle.mul(rate).div(RateDenominator);
                    uint256 bonusValidator = bonusSingle - bonusInvestor;
                    if(bonusInvestor > 0) {
                        iVal.AddBonus{value : bonusInvestor}();
                    }
                    if(bonusValidator > 0) {
                        iVal.BuyStocks{value : bonusValidator}(iVal.OwnerAddress());
                    }
                }
                if(cpFee > 0) {
                    sendValue(gCommunityAddress, cpFee);
                }
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
            _topValidators[i] = cur.SingerAddress();
            cur = topValidators.next[cur];
        }
        return _topValidators;
    }

    function updateActiveValidatorSet(address[] memory newSet)
    external
    onlyLocal
    onlyOperateOnce(Operation.UpdateValidators)
    onlyBlockEpoch
    {
        require(newSet.length > 0, "E18");
        gActiveValidators = newSet;
    }

    function getActiveValidators() external view returns (address[] memory){
        return gActiveValidators;
    }

    function lazyPunish(address singer)
        external
        onlyLocal
        onlyExistValidator(singer)
        onlyOperateOnce(Operation.LazyPunish){
        // TODO
    }

    function decreaseMissedBlocksCounter()
        external
        onlyLocal
        onlyBlockEpoch
        onlyOperateOnce(Operation.DecreaseMissingBlockCounter){
        // TODO
    }

    function doubleSignPunish(bytes32 punishHash, address singer)
    external
    onlyLocal
    onlyExistValidator(singer)
    onlyNotDoubleSignPunished(punishHash)
    {
        doubleSignPunished[punishHash] = true;
        // TODO
    }

    function isDoubleSignPunished(bytes32 punishHash) public view returns (bool) {
        return doubleSignPunished[punishHash];
    }

    function TotalAssets(address singer, address holder) public view returns (uint256) {
        IValidator iVal = gValidatorsMap[singer];
        return iVal.SelfAssets(holder);
    }

    function TotalStocks(address singer, address holder) public view returns (uint256) {
        IValidator iVal = gValidatorsMap[singer];
        return iVal.SelfStocks(holder);
    }

    function TotalStake(address singer) public view returns (uint256) {
        IValidator iVal = gValidatorsMap[singer];
        return iVal.TotalStake();
    }

    function TotalStock(address singer) public view returns (uint256) {
        IValidator iVal = gValidatorsMap[singer];
        return iVal.TotalStock();
    }

    function SingerRate(address singer) public view returns (uint256) {
        IValidator iVal = gValidatorsMap[singer];
        return iVal.SingerRate();
    }

    function OwnerAddress(address singer) public view returns (address) {
        IValidator iVal = gValidatorsMap[singer];
        return iVal.OwnerAddress();
    }

    function SingerState(address singer) public view returns (uint8) {
        IValidator iVal = gValidatorsMap[singer];
        return iVal.SingerState();
    }

    function IsAcceptDelegation(address singer) public view returns (bool) {
        IValidator iVal = gValidatorsMap[singer];
        return iVal.IsAcceptDelegation();
    }

    function IsHolderExist(address singer, address holder) public view returns (bool) {
        IValidator iVal = gValidatorsMap[singer];
        return iVal.IsHolderExist(holder);
    }

    function HolderAddressesLength(address singer) public view returns (uint256) {
        IValidator iVal = gValidatorsMap[singer];
        return iVal.HolderAddressesLength();
    }

    function HolderAddresses(address singer, uint256 startIndex, uint256 count) public view returns (address[] memory) {
        IValidator iVal = gValidatorsMap[singer];
        return iVal.HolderAddresses(startIndex, count);
    }
}
