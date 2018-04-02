pragma solidity ^0.4.18;

//Simple interface that any module contracts should implement
interface IModuleRegistry {

    //Checks that module is correctly configured in registry
    function useModule(address _moduleFactory) external;

    function registerModule(address _moduleFactory) external returns(bool);

}

/**
 * @title Ownable
 * @dev The Ownable contract has an owner address, and provides basic authorization control
 * functions, this simplifies the implementation of "user permissions".
 */
contract Ownable {
  address public owner;


  event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);


  /**
   * @dev The Ownable constructor sets the original `owner` of the contract to the sender
   * account.
   */
  function Ownable() public {
    owner = msg.sender;
  }

  /**
   * @dev Throws if called by any account other than the owner.
   */
  modifier onlyOwner() {
    require(msg.sender == owner);
    _;
  }

  /**
   * @dev Allows the current owner to transfer control of the contract to a newOwner.
   * @param newOwner The address to transfer ownership to.
   */
  function transferOwnership(address newOwner) public onlyOwner {
    require(newOwner != address(0));
    OwnershipTransferred(owner, newOwner);
    owner = newOwner;
  }

}

/**
 * @title ERC20Basic
 * @dev Simpler version of ERC20 interface
 * @dev see https://github.com/ethereum/EIPs/issues/179
 */
contract ERC20Basic {
  function totalSupply() public view returns (uint256);
  function balanceOf(address who) public view returns (uint256);
  function transfer(address to, uint256 value) public returns (bool);
  event Transfer(address indexed from, address indexed to, uint256 value);
}

/**
 * @title ERC20 interface
 * @dev see https://github.com/ethereum/EIPs/issues/20
 */
contract ERC20 is ERC20Basic {
  function allowance(address owner, address spender) public view returns (uint256);
  function transferFrom(address from, address to, uint256 value) public returns (bool);
  function approve(address spender, uint256 value) public returns (bool);
  event Approval(address indexed owner, address indexed spender, uint256 value);
}

//Simple interface that any module contracts should implement
contract IModuleFactory is Ownable {

    ERC20 public polyToken;

    //Should create an instance of the Module, or throw
    function deploy(bytes _data) external returns(address);

    function getType() view external returns(uint8);

    function getName() view external returns(bytes32);

    //Return the cost (in POLY) to use this factory
    function getCost() view external returns(uint256);

    function getDescription() view external returns(string);

    function getTitle() view external returns(string);

    //Pull function sig from _data
    function getSig(bytes _data) internal pure returns (bytes4 sig) {
        uint l = _data.length < 4 ? _data.length : 4;
        for (uint i = 0; i < l; i++) {
            sig = bytes4(uint(sig) + uint(_data[i]) * (2 ** (8 * (l - 1 - i))));
        }
    }

}

contract IST20 {

    // off-chain hash
    bytes32 public tokenDetails;

    //transfer, transferFrom must respect use respect the result of verifyTransfer
    function verifyTransfer(address _from, address _to, uint256 _amount) view public returns (bool success);

    //used to create tokens
    function mint(address _investor, uint256 _amount) public returns (bool success);
}

contract ISecurityToken is IST20, Ownable {

    //TODO: Factor out more stuff here
    function checkPermission(address _delegate, address _module, bytes32 _perm) view public returns(bool);

}

contract ISecurityTokenRegistry {

    address public polyAddress;

    address public moduleRegistry;
    address public tickerRegistry;

    bytes32 public protocolVersion = "0.0.1";
    mapping (bytes32 => address) public protocolVersionST;

    struct SecurityTokenData {
      string symbol;
      bytes32 tokenDetails;
    }

    mapping(address => SecurityTokenData) securityTokens;
    mapping(string => address) symbols;

    /**
     * @dev Creates a new Security Token and saves it to the registry
     * @param _name Name of the token 
     * @param _symbol Ticker symbol of the security token
     * @param _decimals Decimals value for token
     * @param _tokenDetails off-chain details of the token
     */
    function generateSecurityToken(string _name, string _symbol, uint8 _decimals, bytes32 _tokenDetails) public;

    function setProtocolVersion(address _stVersionProxyAddress, bytes32 _version) public;

    //////////////////////////////
    ///////// Get Functions
    //////////////////////////////
    /**
     * @dev Get security token address by ticker name
     * @param _symbol Symbol of the Scurity token
     * @return address _symbol
     */
    function getSecurityTokenAddress(string _symbol) public view returns (address);

     /**
     * @dev Get security token data by its address
     * @param _securityToken Address of the Scurity token
     * @return string, address, bytes32
     */
    function getSecurityTokenData(address _securityToken) public view returns (string, address, bytes32);
}

/**
* @title ModuleRegistry
* @notice Stores registered modules
* Could initially be centrally controlled (only Polymath can register modules)
* and then over time move to a more decentralised version (modules can be registerd provided POLY holders agree)
*/
contract ModuleRegistry is IModuleRegistry, Ownable {

    mapping (address => uint8) public registry;
    mapping (address => address[]) public reputation;
    mapping (uint8 => address[]) public moduleList;
    mapping (address => bool) public verified;

    address public securityTokenRegistry;

    event LogModuleUsed(address indexed _moduleFactory, address indexed _securityToken);
    event LogModuleRegistered(address indexed _moduleFactory, address indexed _owner);
    event LogModuleVerified(address indexed _moduleFactory, bool _verified);

    //Checks that module is correctly configured in registry
    function useModule(address _moduleFactory) external {
        //msg.sender must be a security token - below will throw if not
        ISecurityTokenRegistry(securityTokenRegistry).getSecurityTokenData(msg.sender);
        require(registry[_moduleFactory] != 0);
        //To use a module, either it must be verified, or owned by the ST owner
        require(verified[_moduleFactory] || (IModuleFactory(_moduleFactory).owner() == ISecurityToken(msg.sender).owner()));
        reputation[_moduleFactory].push(msg.sender);
        LogModuleUsed(_moduleFactory, msg.sender);
    }

    //Sets the securityTokenRegistry so that moduleRegistry can validate security tokens are genuine
    function setTokenRegistry(address _securityTokenRegistry) public onlyOwner {
        require(_securityTokenRegistry != address(0));
        securityTokenRegistry = _securityTokenRegistry;
    }

    /**
    * @dev Called by Polymath to register new modules for SecurityToken to use
    * @param _moduleFactory is the address of the module factory to be registered
    */
    function registerModule(address _moduleFactory) external returns(bool) {
        require(registry[_moduleFactory] == 0);
        IModuleFactory moduleFactory = IModuleFactory(_moduleFactory);
        require(moduleFactory.getType() != 0);
        registry[_moduleFactory] = moduleFactory.getType();
        moduleList[moduleFactory.getType()].push(_moduleFactory);
        reputation[_moduleFactory] = new address[](0);
        LogModuleRegistered(_moduleFactory, moduleFactory.owner());
        return true;
    }

    function verifyModule(address _moduleFactory, bool _verified) external onlyOwner returns(bool) {
        //Must already have been registered
        require(registry[_moduleFactory] != 0);
        verified[_moduleFactory] = _verified;
        LogModuleVerified(_moduleFactory, _verified);
        return true;
    }

}