pragma solidity ^0.4.23;

import "./ICheckpoint.sol";
import "../../interfaces/ISecurityToken.sol";
import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/math/Math.sol";

contract EtherDividendCheckpoint is ICheckpoint {
    using SafeMath for uint256;

    struct Dividend {
      uint256 checkpointId;
      uint256 created; // Time at which the dividend was created
      uint256 maturity; // Time after which dividend can be claimed - set to 0 to bypass
      uint256 expiry;  // Time until which dividend can be claimed - after this time any remaining amount can be withdrawn by issuer - set to very high value to bypass
      uint256 amount; // Dividend amount in WEI
      uint256 claimedAmount; // Amount of dividend claimed so far
      uint256 totalSupply; // Total supply at the associated checkpoint (avoids recalculating this)
      bool reclaimed;
      mapping (address => bool) claimed; // List of addresses which have claimed dividend
    }

    // List of all dividends
    Dividend[] public dividends;

    event EtherDividendDeposited(address indexed _depositor, uint256 _checkpointId, uint256 _created, uint256 _maturity, uint256 _expiry, uint256 _amount, uint256 _totalSupply, uint256 _dividendIndex);
    event EtherDividendClaimed(address indexed _payee, uint256 _dividendIndex, uint256 _amount);
    event EtherDividendReclaimed(address indexed _claimer, uint256 _dividendIndex, uint256 _claimedAmount);

    modifier validDividendIndex(uint256 _dividendIndex) {
        require(_dividendIndex < dividends.length, "Incorrect dividend index");
        require(now >= dividends[_dividendIndex].maturity, "Dividend maturity is in the future");
        require(now < dividends[_dividendIndex].expiry, "Dividend expiry is in the past");
        require(dividends[_dividendIndex].reclaimed == false, "Dividend has been reclaimed by issuer");
        _;
    }

    /**
     * @dev Constructor
     * @param _securityToken Address of the security token
     * @param _polyAddress Address of the polytoken
     */
    constructor (address _securityToken, address _polyAddress) public
    IModule(_securityToken, _polyAddress)
    {
    }

    /**
    * @dev Init function i.e generalise function to maintain the structure of the module contract
    * @return bytes4
    */
    function getInitFunction() public returns(bytes4) {
        return bytes4(0);
    }

    /**
     * @dev Creates a dividend and checkpoint for the dividend
     * @param _maturity Time from which dividend can be paid
     * @param _expiry Time until dividend can no longer be paid, and can be reclaimed by issuer
     */
    function createDividend(uint256 _maturity, uint256 _expiry) payable public onlyOwner {
        require(_expiry > _maturity);
        uint256 dividendIndex = dividends.length;
        uint256 checkpointId = ISecurityToken(securityToken).createCheckpoint();
        uint256 currentSupply = ISecurityToken(securityToken).totalSupply();
        dividends.push(
          Dividend(
            checkpointId,
            now,
            _maturity,
            _expiry,
            msg.value,
            0,
            currentSupply,
            false
          )
        );
        emit EtherDividendDeposited(msg.sender, checkpointId, now, _maturity, _expiry, msg.value, currentSupply, dividendIndex);
    }

    /**
     * @dev Creates a dividend with a provided checkpoint
     * @param _maturity Time from which dividend can be paid
     * @param _expiry Time until dividend can no longer be paid, and can be reclaimed by issuer
     */
    function createDividendWithCheckpoint(uint256 _maturity, uint256 _expiry, uint256 _checkpointId) payable public onlyOwner {
        require(_expiry > _maturity);
        require(_checkpointId <= ISecurityToken(securityToken).currentCheckpointId());
        uint256 dividendIndex = dividends.length;
        uint256 currentSupply = ISecurityToken(securityToken).totalSupplyAt(_checkpointId);
        dividends.push(
          Dividend(
            _checkpointId,
            now,
            _maturity,
            _expiry,
            msg.value,
            0,
            currentSupply,
            false
          )
        );
        emit EtherDividendDeposited(msg.sender, _checkpointId, now, _maturity, _expiry, msg.value, currentSupply, dividendIndex);
    }

    /**
     * @dev Issuer can push dividends to provided addresses
     * @param _dividendIndex Dividend to push
     * @param _payees Addresses to which to push the dividend
     */
    function pushDividendPaymentToAddresses(uint256 _dividendIndex, address[] _payees) public onlyOwner validDividendIndex(_dividendIndex) {
        Dividend storage dividend = dividends[_dividendIndex];
        for (uint256 i = 0; i < _payees.length; i++) {
            if (!dividend.claimed[_payees[i]]) {
                _payDividend(_payees[i], dividend, _dividendIndex);
            }
        }
    }

    /**
     * @dev Issuer can push dividends using the investor list from the security token
     * @param _dividendIndex Dividend to push
     * @param _start Index in investor list at which to start pushing dividends
     * @param _iterations Number of addresses to push dividends for
     */
    function pushDividendPayment(uint256 _dividendIndex, uint256 _start, uint256 _iterations) public onlyOwner validDividendIndex(_dividendIndex) {
        Dividend storage dividend = dividends[_dividendIndex];
        uint256 numberInvestors = ISecurityToken(securityToken).getInvestorsLength();
        for (uint256 i = _start; i < Math.min256(numberInvestors, _start.add(_iterations)); i++) {
            address payee = ISecurityToken(securityToken).investors(i);
            if (!dividend.claimed[payee]) {
                _payDividend(payee, dividend, _dividendIndex);
            }
        }
    }

    /**
     * @dev Investors can pull their own dividends
     * @param _dividendIndex Dividend to pull
     */
    function pullDividendPayment(uint256 _dividendIndex) public validDividendIndex(_dividendIndex)
    {
        Dividend storage dividend = dividends[_dividendIndex];
        require(dividend.claimed[msg.sender] == false);
        _payDividend(msg.sender, dividend, _dividendIndex);
    }

    function _payDividend(address _payee, Dividend storage _dividend, uint256 _dividendIndex) internal {
        uint256 balance = ISecurityToken(securityToken).balanceOfAt(_payee, _dividend.checkpointId);
        uint256 claim = balance.mul(_dividend.amount).div(_dividend.totalSupply);
        _dividend.claimed[_payee] = true;
        _dividend.claimedAmount = claim.add(_dividend.claimedAmount);
        if (claim > 0) {
            _payee.transfer(claim);
            emit EtherDividendClaimed(_payee, _dividendIndex, claim);
        }
    }

    /**
     * @dev Issuer can reclaim remaining unclaimed dividend amounts, for expired dividends
     * @param _dividendIndex Dividend to reclaim
     */
    function reclaimDividend(uint256 _dividendIndex) public onlyOwner {
        require(_dividendIndex < dividends.length, "Incorrect dividend index");
        require(now >= dividends[_dividendIndex].expiry, "Dividend expiry is in the future");
        require(!dividends[_dividendIndex].reclaimed, "Dividend already claimed");
        dividends[_dividendIndex].reclaimed = true;
        Dividend storage dividend = dividends[_dividendIndex];
        uint256 remainingAmount = dividend.amount.sub(dividend.claimedAmount);
        msg.sender.transfer(remainingAmount);
        emit EtherDividendReclaimed(msg.sender, _dividendIndex, remainingAmount);
    }

    /**
     * @notice Return the permissions flag that are associated with STO
     */
    function getPermissions() public view returns(bytes32[]) {
        bytes32[] memory allPermissions = new bytes32[](0);
        return allPermissions;
    }

}