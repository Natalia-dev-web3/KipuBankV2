// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Imports
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title KipuBankV2
 * @author Natalia Avila
 * @notice Banco descentralizado con soporte multi-token y conversión a USD
 * @dev Implementa AccessControl, ReentrancyGuard, Chainlink y normalización de decimales a 6 (USDC)
 */
contract KipuBankV2 is AccessControl, ReentrancyGuard {
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
    
    /// @notice Decimales de cada token ERC20 para normalización
    mapping(address => uint8) private s_tokenDecimals;
    
    /// @notice Array de tokens para cálculo de balance total
    address[] private s_tokenList;

    // Contadores
    uint256 private s_totalDeposits;
    uint256 private s_totalWithdrawals;

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
    error KipuBankV2__OracleCompromised();
    error KipuBankV2__StalePrice();
    error KipuBankV2__TokenNotSupported();
    error KipuBankV2__TokenAlreadySupported();
    error KipuBankV2__InvalidToken();

    // Modificadores
    modifier amountGreaterThanZero(uint256 amount) {
        if (amount == 0) revert KipuBankV2__AmountMustBeGreaterThanZero();
        _;
    }

    /**
     * @notice Constructor del contrato
     * @param bankCapUSD Límite máximo del banco en USD (6 decimales)
     * @param withdrawalLimitUSD Límite de retiro por transacción en USD (6 decimales)
     * @param ethUsdFeed Dirección del oráculo Chainlink ETH/USD
     * @param admin Dirección del administrador inicial
     */
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
    /**
     * @notice Recibe ETH cuando se envía directamente al contrato
     * @dev Llama a _depositETH internamente
     */
    receive() external payable {
        _depositETH();
    }

    /**
     * @notice Fallback para recibir ETH con datos
     * @dev Llama a _depositETH internamente
     */
    fallback() external payable {
        _depositETH();
    }

    // Funciones Externas - Depósitos
    
    /**
     * @notice Deposita ETH en el banco
     * @dev Convierte el valor a USD usando Chainlink y actualiza balances
     */
    function depositETH() external payable nonReentrant {
        _depositETH();
    }

    /**
     * @notice Deposita tokens ERC-20 en el banco
     * @dev El token debe estar en la whitelist y tener decimales configurados
     * @param token Dirección del token a depositar
     * @param amount Cantidad a depositar en unidades del token
     */
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
    
    /**
     * @notice Retira ETH del banco
     * @dev Valida límites en USD antes de permitir el retiro
     * @param amount Cantidad de ETH a retirar en wei
     */
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

    /**
     * @notice Retira tokens ERC-20 del banco
     * @param token Dirección del token a retirar
     * @param amount Cantidad a retirar en unidades del token
     */
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
    
    /**
     * @notice Actualiza el feed de Chainlink para ETH/USD
     * @dev Solo puede ser llamado por ADMIN_ROLE
     * @param newFeed Nueva dirección del price feed
     */
    function setEthUsdFeed(address newFeed) external onlyRole(ADMIN_ROLE) {
        s_ethUsdFeed = AggregatorV3Interface(newFeed);
        emit FeedUpdated(newFeed);
    }

    /**
     * @notice Agrega un token a la whitelist
     * @dev Solo puede ser llamado por ADMIN_ROLE. Obtiene automáticamente los decimales del token
     * @param token Dirección del token a agregar
     */
    function addSupportedToken(address token) external onlyRole(ADMIN_ROLE) {
        if (s_supportedTokens[token]) revert KipuBankV2__TokenAlreadySupported();
        
        // Obtener decimales del token
        try IERC20Metadata(token).decimals() returns (uint8 dec) {
            s_tokenDecimals[token] = dec;
        } catch {
            revert KipuBankV2__InvalidToken();
        }
        
        s_supportedTokens[token] = true;
        s_tokenList.push(token);
        
        emit TokenAdded(token);
    }

    /**
     * @notice Remueve un token de la whitelist
     * @dev Solo puede ser llamado por ADMIN_ROLE
     * @param token Dirección del token a remover
     */
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
    
    /**
     * @notice Obtiene el balance de un usuario para un token específico
     * @param user Dirección del usuario
     * @param token Dirección del token (address(0) para ETH)
     * @return Balance del usuario en USD con 6 decimales
     */
    function getUserBalance(address user, address token) external view returns (uint256) {
        return s_userBalances[user][token];
    }

    /**
     * @notice Obtiene el balance total del banco en USD
     * @return Balance total en USD con 6 decimales
     */
    function getTotalBankBalanceUSD() external view returns (uint256) {
        return _getTotalBankBalanceUSD();
    }

    /**
     * @notice Calcula el espacio disponible antes de alcanzar el bank cap
     * @return Espacio disponible en USD con 6 decimales
     */
    function getAvailableSpaceUSD() external view returns (uint256) {
        uint256 currentBalance = _getTotalBankBalanceUSD();
        if (currentBalance >= BANK_CAP_USD) return 0;
        return BANK_CAP_USD - currentBalance;
    }

    /**
     * @notice Obtiene el precio actual de ETH en USD desde Chainlink
     * @return Precio de ETH en USD con 8 decimales
     */
    function getEthUsdPrice() external view returns (uint256) {
        return _getEthUsdPrice();
    }

    /**
     * @notice Obtiene los contadores de depósitos y retiros
     * @return deposits Total de depósitos realizados
     * @return withdrawals Total de retiros realizados
     */
    function getCounters() external view returns (uint256 deposits, uint256 withdrawals) {
        return (s_totalDeposits, s_totalWithdrawals);
    }

    /**
     * @notice Verifica si un token está soportado
     * @param token Dirección del token a verificar
     * @return true si el token está soportado, false en caso contrario
     */
    function isTokenSupported(address token) external view returns (bool) {
        return s_supportedTokens[token];
    }

    /**
     * @notice Obtiene la lista de todos los tokens soportados
     * @return Array con las direcciones de los tokens soportados
     */
    function getSupportedTokens() external view returns (address[] memory) {
        return s_tokenList;
    }

    // Funciones Privadas
    
    /**
     * @dev Función interna para depositar ETH
     * @notice Convierte ETH a USD y actualiza los balances
     */
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

    /**
     * @dev Convierte una cantidad de ETH a USD
     * @param ethAmount Cantidad de ETH en wei
     * @return Valor equivalente en USD con 6 decimales
     */
    function _convertEthToUSD(uint256 ethAmount) private view returns (uint256) {
        uint256 ethUsdPrice = _getEthUsdPrice();
        // ethAmount (18 dec) * price (8 dec) / 10^20 = USD (6 dec)
        return (ethAmount * ethUsdPrice) / DECIMAL_FACTOR;
    }

    /**
     * @dev Convierte una cantidad de token ERC-20 a USD normalizado a 6 decimales
     * @param token Dirección del token
     * @param amount Cantidad del token en sus unidades nativas
     * @return Valor equivalente en USD con 6 decimales
     */
    function _convertTokenToUSD(address token, uint256 amount) private returns (uint256) {
        if (token == ETH_ADDRESS) {
            return _convertEthToUSD(amount);
        }
        
        uint8 tokenDecimals = s_tokenDecimals[token];
        
        // Si no tenemos los decimales guardados, obtenerlos
        if (tokenDecimals == 0) {
            try IERC20Metadata(token).decimals() returns (uint8 dec) {
                tokenDecimals = dec;
                s_tokenDecimals[token] = dec;
            } catch {
                revert KipuBankV2__InvalidToken();
            }
        }
        
        // Normalizar a 6 decimales (USDC)
        if (tokenDecimals > USDC_DECIMALS) {
            return amount / (10 ** (tokenDecimals - USDC_DECIMALS));
        } else if (tokenDecimals < USDC_DECIMALS) {
            return amount * (10 ** (USDC_DECIMALS - tokenDecimals));
        } else {
            return amount;
        }
    }

    /**
     * @dev Obtiene el precio de ETH desde Chainlink con validaciones completas
     * @return Precio de ETH en USD con 8 decimales
     */
    function _getEthUsdPrice() private view returns (uint256) {
        (
            uint80 roundId,
            int256 price,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = s_ethUsdFeed.latestRoundData();

        // Validar que el precio sea positivo
        if (price <= 0) revert KipuBankV2__OracleCompromised();
        
        // Validar que el precio no sea obsoleto (< 1 hora)
        if (block.timestamp - updatedAt > ORACLE_HEARTBEAT) {
            revert KipuBankV2__StalePrice();
        }
        
        // Validar que la respuesta sea del round más reciente
        if (answeredInRound < roundId) {
            revert KipuBankV2__StalePrice();
        }

        return uint256(price);
    }

    /**
     * @dev Calcula el balance total del banco sumando todos los tokens
     * @return Balance total en USD con 6 decimales
     */
    function _getTotalBankBalanceUSD() private view returns (uint256) {
        uint256 total = 0;
        
        // Sumar balance de todos los tokens soportados
        for (uint256 i = 0; i < s_tokenList.length; i++) {
            total += s_tokenBalances[s_tokenList[i]];
        }
        
        return total;
    }

    /**
     * @dev Transfiere ETH de forma segura
     * @param to Dirección destino
     * @param amount Cantidad de ETH en wei
     */
    function _safeTransferETH(address to, uint256 amount) private {
        (bool success,) = payable(to).call{value: amount}("");
        if (!success) revert KipuBankV2__TransferFailed();
    }
}
