// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Imports
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title KipuBankV2
 * @author Natalia Avila
 * @notice Banco descentralizado con soporte multi-token y conversión a USD
 * @dev Implementa AccessControl, Chainlink y normalización de decimales a 6 (USDC)
 */
contract KipuBankV2 is AccessControl {
    // Declaración de Tipos
    using SafeERC20 for IERC20;

    // Roles
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // Variables Immutable
    /// @notice Límite máximo del banco en USD (6 decimales)
    uint256 public immutable BANK_CAP_USD;
    
    /// @notice Límite de retiro por transacción en USD (6 decimales)
    uint256 public immutable WITHDRAWAL_LIMIT_USD;

    // Variables Constant
    /// @notice Heartbeat del oráculo Chainlink (3600 segundos = 1 hora)
    uint16 private constant ORACLE_HEARTBEAT = 3600;
    
    /// @notice Factor de conversión de decimales (10^20 = de 18+8 a 6 decimales)
    uint256 private constant DECIMAL_FACTOR = 1e20;
    
    /// @notice Decimales de USDC
    uint8 private constant USDC_DECIMALS = 6;
    
    /// @notice Dirección que representa ETH nativo
    address private constant ETH_ADDRESS = address(0);

    // Instancia del Oráculo
    /// @notice Oráculo de Chainlink para ETH/USD
    AggregatorV3Interface private s_ethUsdFeed;

    // Mappings Anidados
    /// @notice Balance de cada usuario por token (normalizado a 6 decimales)
    mapping(address => mapping(address => uint256)) private s_userBalances;
    
    /// @notice Balance total del banco por token (normalizado a 6 decimales)
    mapping(address => uint256) private s_tokenBalances;
    
    /// @notice Tokens ERC20 soportados por el banco
    mapping(address => bool) private s_supportedTokens;
    
    /// @notice Array de tokens para cálculo de balance total
    address[] private s_tokenList;

    // Contadores
    uint256 private s_totalDeposits;
    uint256 private s_totalWithdrawals;

    // Protección contra reentrancy
    bool private locked;

    // Eventos
    event Deposit(address indexed user, address indexed token, uint256 amount, uint256 amountUSD);
    event Withdrawal(address indexed user, address indexed token, uint256 amount, uint256 amountUSD);
    event FeedUpdated(address indexed newFeed);
    event TokenAdded(address indexed token);
    event TokenRemoved(address indexed token);

    // Errores Personalizados
    error KipuBankV2__AmountMustBeGreaterThanZero();
    error KipuBankV2__DepositExceedsBankCap(uint256 attempted, uint256 available);
    error KipuBankV2__WithdrawalExceedsLimit(uint256 attempted, uint256 limit);
    error KipuBankV2__InsufficientBalance(uint256 requested, uint256 available);
    error KipuBankV2__TransferFailed();
    error KipuBankV2__ReentrancyDetected();
    error KipuBankV2__OracleCompromised();
    error KipuBankV2__StalePrice();
    error KipuBankV2__TokenNotSupported();
    error KipuBankV2__TokenAlreadySupported();

    // Modificadores
    modifier nonReentrant() {
        if (locked) revert KipuBankV2__ReentrancyDetected();
        locked = true;
        _;
        locked = false;
    }

    modifier amountGreaterThanZero(uint256 amount) {
        if (amount == 0) revert KipuBankV2__AmountMustBeGreaterThanZero();
        _;
    }

    // Constructor
    constructor(
        uint256 bankCapUSD,
        uint256 withdrawalLimitUSD,
        address ethUsdFeed,
        address admin
    ) {
        BANK_CAP_USD = bankCapUSD;
        WITHDRAWAL_LIMIT_USD = withdrawalLimitUSD;
        s_ethUsdFeed = AggregatorV3Interface(ethUsdFeed);
        
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        
        // ETH siempre soportado
        s_supportedTokens[ETH_ADDRESS] = true;
        s_tokenList.push(ETH_ADDRESS);
    }

    // Funciones de Recepción
    receive() external payable {
        _depositETH();
    }

    fallback() external payable {
        _depositETH();
    }

    // Funciones Externas - Depósitos
    function depositETH() external payable nonReentrant {
        _depositETH();
    }

    function depositERC20(address token, uint256 amount)
        external
        nonReentrant
        amountGreaterThanZero(amount)
    {
        if (!s_supportedTokens[token]) revert KipuBankV2__TokenNotSupported();

        uint256 amountUSD = _convertTokenToUSD(token, amount);

        // Checks
        uint256 totalBankBalanceUSD = _getTotalBankBalanceUSD();
        if (totalBankBalanceUSD + amountUSD > BANK_CAP_USD) {
            revert KipuBankV2__DepositExceedsBankCap(
                amountUSD,
                BANK_CAP_USD - totalBankBalanceUSD
            );
        }

        // Effects
        s_userBalances[msg.sender][token] += amountUSD;
        s_tokenBalances[token] += amountUSD;
        s_totalDeposits++;

        // Interactions
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        emit Deposit(msg.sender, token, amount, amountUSD);
    }

    // Funciones Externas - Retiros
    function withdrawETH(uint256 amount)
        external
        nonReentrant
        amountGreaterThanZero(amount)
    {
        uint256 amountUSD = _convertEthToUSD(amount);

        // Checks
        if (amountUSD > WITHDRAWAL_LIMIT_USD) {
            revert KipuBankV2__WithdrawalExceedsLimit(amountUSD, WITHDRAWAL_LIMIT_USD);
        }

        uint256 userBalance = s_userBalances[msg.sender][ETH_ADDRESS];
        if (amountUSD > userBalance) {
            revert KipuBankV2__InsufficientBalance(amountUSD, userBalance);
        }

        // Effects
        s_userBalances[msg.sender][ETH_ADDRESS] -= amountUSD;
        s_tokenBalances[ETH_ADDRESS] -= amountUSD;
        s_totalWithdrawals++;

        // Interactions
        _safeTransferETH(msg.sender, amount);

        emit Withdrawal(msg.sender, ETH_ADDRESS, amount, amountUSD);
    }

    function withdrawERC20(address token, uint256 amount)
        external
        nonReentrant
        amountGreaterThanZero(amount)
    {
        if (!s_supportedTokens[token]) revert KipuBankV2__TokenNotSupported();

        uint256 amountUSD = _convertTokenToUSD(token, amount);

        // Checks
        if (amountUSD > WITHDRAWAL_LIMIT_USD) {
            revert KipuBankV2__WithdrawalExceedsLimit(amountUSD, WITHDRAWAL_LIMIT_USD);
        }

        uint256 userBalance = s_userBalances[msg.sender][token];
        if (amountUSD > userBalance) {
            revert KipuBankV2__InsufficientBalance(amountUSD, userBalance);
        }

        // Effects
        s_userBalances[msg.sender][token] -= amountUSD;
        s_tokenBalances[token] -= amountUSD;
        s_totalWithdrawals++;

        // Interactions
        IERC20(token).safeTransfer(msg.sender, amount);

        emit Withdrawal(msg.sender, token, amount, amountUSD);
    }

    // Funciones Administrativas
    function setEthUsdFeed(address newFeed) external onlyRole(ADMIN_ROLE) {
        s_ethUsdFeed = AggregatorV3Interface(newFeed);
        emit FeedUpdated(newFeed);
    }

    function addSupportedToken(address token) external onlyRole(ADMIN_ROLE) {
        if (s_supportedTokens[token]) revert KipuBankV2__TokenAlreadySupported();
        
        s_supportedTokens[token] = true;
        s_tokenList.push(token);
        
        emit TokenAdded(token);
    }

    function removeSupportedToken(address token) external onlyRole(ADMIN_ROLE) {
        if (!s_supportedTokens[token]) revert KipuBankV2__TokenNotSupported();
        
        s_supportedTokens[token] = false;
        
        // Remover del array
        for (uint256 i = 0; i < s_tokenList.length; i++) {
            if (s_tokenList[i] == token) {
                s_tokenList[i] = s_tokenList[s_tokenList.length - 1];
                s_tokenList.pop();
                break;
            }
        }
        
        emit TokenRemoved(token);
    }

    // Funciones de Vista
    function getUserBalance(address user, address token) external view returns (uint256) {
        return s_userBalances[user][token];
    }

    function getTotalBankBalanceUSD() external view returns (uint256) {
        return _getTotalBankBalanceUSD();
    }

    function getAvailableSpaceUSD() external view returns (uint256) {
        uint256 currentBalance = _getTotalBankBalanceUSD();
        if (currentBalance >= BANK_CAP_USD) return 0;
        return BANK_CAP_USD - currentBalance;
    }

    function getEthUsdPrice() external view returns (uint256) {
        return _getEthUsdPrice();
    }

    function getCounters() external view returns (uint256 deposits, uint256 withdrawals) {
        return (s_totalDeposits, s_totalWithdrawals);
    }

    function isTokenSupported(address token) external view returns (bool) {
        return s_supportedTokens[token];
    }

    function getSupportedTokens() external view returns (address[] memory) {
        return s_tokenList;
    }

    // Funciones Privadas
    function _depositETH() private amountGreaterThanZero(msg.value) {
        uint256 amountUSD = _convertEthToUSD(msg.value);

        // Checks
        uint256 totalBankBalanceUSD = _getTotalBankBalanceUSD();
        if (totalBankBalanceUSD + amountUSD > BANK_CAP_USD) {
            revert KipuBankV2__DepositExceedsBankCap(
                amountUSD,
                BANK_CAP_USD - totalBankBalanceUSD
            );
        }

        // Effects
        s_userBalances[msg.sender][ETH_ADDRESS] += amountUSD;
        s_tokenBalances[ETH_ADDRESS] += amountUSD;
        s_totalDeposits++;

        emit Deposit(msg.sender, ETH_ADDRESS, msg.value, amountUSD);
    }

    function _convertEthToUSD(uint256 ethAmount) private view returns (uint256) {
        uint256 ethUsdPrice = _getEthUsdPrice();
        // ethAmount (18 dec) * price (8 dec) / 10^20 = USD (6 dec)
        return (ethAmount * ethUsdPrice) / DECIMAL_FACTOR;
    }

    function _convertTokenToUSD(address token, uint256 amount) private pure returns (uint256) {
        // Asumimos que los tokens soportados tienen 6 decimales (como USDC)
        // En una implementación real, necesitarías consultar decimals() del token
        return amount;
    }

    function _getEthUsdPrice() private view returns (uint256) {
        (, int256 price,, uint256 updatedAt,) = s_ethUsdFeed.latestRoundData();

        if (price <= 0) revert KipuBankV2__OracleCompromised();
        if (block.timestamp - updatedAt > ORACLE_HEARTBEAT) {
            revert KipuBankV2__StalePrice();
        }

        return uint256(price);
    }

    function _getTotalBankBalanceUSD() private view returns (uint256) {
        uint256 total = 0;
        
        // Sumar balance de todos los tokens soportados
        for (uint256 i = 0; i < s_tokenList.length; i++) {
            total += s_tokenBalances[s_tokenList[i]];
        }
        
        return total;
    }

    function _safeTransferETH(address to, uint256 amount) private {
        (bool success,) = payable(to).call{value: amount}("");
        if (!success) revert KipuBankV2__TransferFailed();
    }
}
