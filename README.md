# KipuBankV2 🏦

Evolución del contrato KipuBank con características avanzadas de Solidity, integración de Chainlink y OpenZeppelin.

## 📋 Información del Contrato

- **Red**: Sepolia Testnet
- **Dirección**: `0xD34f388e7712CB21D51Ff1D912b1d464cD061e56`
- **Explorador**: [Ver en Etherscan](https://sepolia.etherscan.io/address/0xD34f388e7712CB21D51Ff1D912b1d464cD061e56)
- **Estado**: ✅ Verificado

---

## 🚀 Mejoras Implementadas

### 1. Control de Acceso
Implementación de `AccessControl` de OpenZeppelin para gestión de roles y permisos.

**Por qué**: Permite administración segura del contrato con roles específicos (ADMIN_ROLE) para funciones sensibles como agregar tokens soportados o actualizar oráculos.

### 2. Soporte Multi-Token
Soporte para ETH nativo y tokens ERC-20 con contabilidad separada por usuario y token.

**Por qué**: Aumenta la utilidad del banco permitiendo múltiples activos. ETH se representa como `address(0)` según convenciones del ecosistema.

**Implementación:**
```solidity
mapping(address => mapping(address => uint256)) private s_userBalances;
// usuario => token => balance (en USD con 6 decimales)
```

### 3. Integración con Chainlink Data Feeds
Usa el oráculo ETH/USD de Chainlink para conversión de valores en tiempo real.

**Por qué**: Permite gestionar límites del banco en USD (valor estable) en lugar de ETH (volátil). Esto protege el capital del banco de fluctuaciones de precio.

**Price Feed usado**: `0x694AA1769357215DE4FAC081bf1f309aDC325306` (Sepolia)

### 4. Conversión de Decimales
Normalización de todos los valores a 6 decimales (estándar USDC) para contabilidad interna.

**Por qué**: Facilita comparaciones entre tokens y reduce complejidad. ETH (18 decimales) y Chainlink feed (8 decimales) se convierten a 6 decimales.

**Ejemplo de conversión:**
```solidity
// ETH (18 dec) * Precio (8 dec) / 10^20 = USD (6 dec)
return (ethAmount * ethUsdPrice) / DECIMAL_FACTOR;
```

### 5. Variables Constant e Immutable
- **Immutable**: `BANK_CAP_USD`, `WITHDRAWAL_LIMIT_USD` (configurables por deployment)
- **Constant**: `ORACLE_HEARTBEAT`, `DECIMAL_FACTOR`, `ETH_ADDRESS`

**Por qué**: Optimización de gas y flexibilidad para configurar límites según el entorno de deployment.

### 6. Eventos y Errores Personalizados
Eventos detallados para tracking off-chain y errores custom para mejor debugging.

**Por qué**: Facilita monitoreo y reduce costos de gas vs strings en require/revert.

### 7. Patrones de Seguridad
- Checks-Effects-Interactions en todas las funciones
- ReentrancyGuard de OpenZeppelin
- SafeERC20 para transferencias de tokens
- Validación de datos del oráculo (precio válido y actualizado)

**Por qué**: Previene vulnerabilidades comunes como reentrancy attacks y maneja tokens no estándar.

---

## 🔄 Correcciones Aplicadas (Post-Revisión)

Basado en el feedback recibido, se implementaron las siguientes mejoras para alcanzar un contrato de nivel producción:

### 1. Validación Completa de Chainlink ✅

**Problema identificado**: Faltaba validar `answeredInRound >= roundId` para detectar respuestas de rounds obsoletas.

**Solución implementada:**
```solidity
function _getEthUsdPrice() private view returns (uint256) {
    (
        uint80 roundId,
        int256 price,
        ,
        uint256 updatedAt,
        uint80 answeredInRound
    ) = s_ethUsdFeed.latestRoundData();

    if (price <= 0) revert KipuBankV2__OracleCompromised();
    if (block.timestamp - updatedAt > ORACLE_HEARTBEAT) {
        revert KipuBankV2__StalePrice();
    }
    
    // ✅ NUEVA VALIDACIÓN
    if (answeredInRound < roundId) {
        revert KipuBankV2__StalePrice();
    }

    return uint256(price);
}
```

**Impacto**: Previene el uso de datos de rounds antiguos que podrían estar desactualizados o manipulados, aumentando la seguridad del oráculo.

---

### 2. Decimales Dinámicos para Tokens ERC-20 ✅

**Problema identificado**: Asunción fija de 6 decimales para todos los tokens ERC-20 limitaba la compatibilidad.

**Solución implementada:**
```solidity
// Nuevo mapping para almacenar decimales de tokens
mapping(address => uint8) private s_tokenDecimals;

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
```

**Impacto**: 
- ✅ Soporta tokens con cualquier cantidad de decimales (USDT: 6, DAI: 18, WBTC: 8, etc.)
- ✅ Normalización automática y correcta a 6 decimales
- ✅ Mayor flexibilidad sin comprometer la seguridad

---

### 3. ReentrancyGuard de OpenZeppelin ✅

**Mejora aplicada**: Reemplazo de implementación manual por el estándar de OpenZeppelin.

**Implementación:**
```solidity
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract KipuBankV2 is AccessControl, ReentrancyGuard {
    
    function depositETH() external payable nonReentrant { ... }
    
    function withdrawETH(uint256 amount) external nonReentrant { ... }
    
    function depositERC20(address token, uint256 amount) external nonReentrant { ... }
    
    function withdrawERC20(address token, uint256 amount) external nonReentrant { ... }
}
```

**Impacto**: 
- ✅ Implementación battle-tested y auditada
- ✅ Mayor confianza en la seguridad del contrato
- ✅ Código más limpio y mantenible

---

### 4. Documentación NatSpec Completa ✅

**Mejora aplicada**: Agregados comentarios NatSpec estándar a todas las funciones públicas y externas.

**Ejemplos:**
```solidity
/**
 * @notice Deposita ETH en el banco
 * @dev Convierte el valor a USD usando Chainlink y actualiza balances
 */
function depositETH() external payable nonReentrant { ... }

/**
 * @notice Retira ETH del banco
 * @dev Valida límites en USD antes de permitir el retiro
 * @param amount Cantidad de ETH a retirar en wei
 */
function withdrawETH(uint256 amount) external nonReentrant { ... }

/**
 * @notice Obtiene el balance de un usuario para un token específico
 * @param user Dirección del usuario
 * @param token Dirección del token (address(0) para ETH)
 * @return Balance del usuario en USD con 6 decimales
 */
function getUserBalance(address user, address token) external view returns (uint256) { ... }

/**
 * @notice Agrega un token a la whitelist
 * @dev Solo puede ser llamado por ADMIN_ROLE. Obtiene automáticamente los decimales del token
 * @param token Dirección del token a agregar
 */
function addSupportedToken(address token) external onlyRole(ADMIN_ROLE) { ... }
```

**Impacto**:
- ✅ Documentación automática generada
- ✅ Facilita auditorías de seguridad
- ✅ Mejor experiencia para desarrolladores
- ✅ Código más profesional y mantenible

---

## 🔧 Decisiones de Diseño

### Límites en USD vs ETH
**Decisión**: Bank cap y límites de retiro en USD (usando Chainlink).

**Trade-off**: Dependencia de oráculos externos, pero proporciona protección real contra volatilidad.

**Ejemplo**: Si el límite es $10,000 USD, siempre será $10,000 sin importar si ETH vale $1,000 o $4,000.

### Whitelist de Tokens
**Decisión**: Solo admin puede agregar tokens soportados.

**Trade-off**: Menos flexible pero más seguro. Previene tokens maliciosos o con comportamientos inesperados (fee-on-transfer).

### Normalización a 6 Decimales
**Decisión**: Toda la contabilidad interna usa 6 decimales.

**Trade-off**: Requiere conversiones pero simplifica cálculos y es compatible con USDC (el stablecoin más usado).

---

## 📦 Instrucciones de Despliegue

### Desplegar con Remix

1. Ir a [Remix IDE](https://remix.ethereum.org/)
2. Crear archivo `KipuBankV2.sol` en la carpeta `contracts/`
3. Compilar con Solidity **0.8.26**
4. En Deploy & Run:
   - **Environment**: Injected Provider (MetaMask)
   - **Network**: Sepolia Testnet
5. Parámetros del constructor:
   - `bankCapUSD`: `10000000000` (10,000 USD con 6 decimales)
   - `withdrawalLimitUSD`: `1000000000` (1,000 USD con 6 decimales)
   - `ethUsdFeed`: `0x694AA1769357215DE4FAC081bf1f309aDC325306` (ETH/USD Sepolia)
   - `admin`: Tu dirección de wallet
6. Click en **Deploy**
7. Verificar en Etherscan usando "Verify & Publish"

---

## 💻 Cómo Interactuar

### Depositar ETH
```bash
# Desde Etherscan: Write Contract → depositETH con value

# Con Cast
cast send 0xD34f388e7712CB21D51Ff1D912b1d464cD061e56 "depositETH()" \
  --value 0.1ether \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY
```

### Depositar ERC-20
```bash
# 1. Aprobar
cast send [TOKEN] "approve(address,uint256)" \
  0xD34f388e7712CB21D51Ff1D912b1d464cD061e56 1000000000

# 2. Depositar
cast send 0xD34f388e7712CB21D51Ff1D912b1d464cD061e56 \
  "depositERC20(address,uint256)" [TOKEN] 1000000000
```

### Consultar Balance
```bash
cast call 0xD34f388e7712CB21D51Ff1D912b1d464cD061e56 \
  "getUserBalance(address,address)" [USER] [TOKEN]
```

### Ver Precio ETH
```bash
cast call 0xD34f388e7712CB21D51Ff1D912b1d464cD061e56 "getEthUsdPrice()"
```

---

## 🔒 Seguridad

### Patrones Implementados
- ✅ Checks-Effects-Interactions
- ✅ ReentrancyGuard
- ✅ Access Control
- ✅ SafeERC20
- ✅ Validación completa de oráculos

### Limitaciones Conocidas
1. **Volatilidad de ETH**: El banco garantiza valor en USD, no cantidad de ETH. Si ETH sube de precio, el usuario recibirá menos ETH al retirar el mismo saldo USD.
2. **Sin mecanismo de pausa**: No implementado por simplicidad, pero recomendable para producción.

---

## 👤 Autor

**Natalia Avila**  
GitHub: [@Natalia-dev-web3](https://github.com/Natalia-dev-web3)

**Proyecto**: Ethereum Developer Pack - Módulo 3 - Examen Final  
**Fecha**: Noviembre 2025

---

