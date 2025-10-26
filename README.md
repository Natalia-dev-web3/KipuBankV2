# KipuBankV2 🏦

Evolución del contrato KipuBank con características avanzadas de Solidity, integración de Chainlink y OpenZeppelin.

## 📋 Información del Contrato

- **Red**: Sepolia Testnet
- **Dirección**: `0x130c613A42DB065b09C68DD685f15af14d7F0B1C`
- **Explorador**: [Ver en Etherscan](https://sepolia.etherscan.io/address/0x130c613A42DB065b09C68DD685f15af14d7F0B1C)
- **Estado**: ✅ Verificado

## 🚀 Mejoras Implementadas

### 1. Control de Acceso
Implementación de `AccessControl` de OpenZeppelin para gestión de roles y permisos.

**Por qué**: Permite administración segura del contrato con roles específicos (ADMIN_ROLE) para funciones sensibles como agregar tokens soportados o actualizar oráculos.

### 2. Soporte Multi-Token
Soporte para ETH nativo y tokens ERC-20 con contabilidad separada por usuario y token.

**Por qué**: Aumenta la utilidad del banco permitiendo múltiples activos. ETH se representa como `address(0)` según convenciones del ecosistema.

**Implementación**:
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

**Ejemplo de conversión**:
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

## 📦 Instrucciones de Despliegue

### Desplegar con Remix

1. Ir a [Remix IDE](https://remix.ethereum.org/)
2. Crear archivo `KipuBankV2.sol` en la carpeta `contracts/`
3. Compilar con Solidity 0.8.20+
4. En Deploy & Run:
   - Environment: Injected Provider (MetaMask)
   - Network: Sepolia Testnet
5. Parámetros del constructor:
   - `bankCapUSD`: `10000000000` (10,000 USD con 6 decimales)
   - `withdrawalLimitUSD`: `1000000000` (1,000 USD con 6 decimales)
   - `ethUsdFeed`: `0x694AA1769357215DE4FAC081bf1f309aDC325306` (ETH/USD Sepolia)
   - `admin`: Tu dirección de wallet
6. Click en **Deploy**
7. Verificar en Etherscan usando "Verify & Publish"

## 💻 Cómo Interactuar

### Depositar ETH
```bash
# Desde Etherscan: Write Contract → depositETH con value

# Con Cast
cast send 0x130c613A42DB065b09C68DD685f15af14d7F0B1C "depositETH()" \
  --value 0.1ether \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY
```

### Depositar ERC-20
```bash
# 1. Aprobar
cast send [TOKEN] "approve(address,uint256)" \
  0x130c613A42DB065b09C68DD685f15af14d7F0B1C 1000000000

# 2. Depositar
cast send 0x130c613A42DB065b09C68DD685f15af14d7F0B1C \
  "depositERC20(address,uint256)" [TOKEN] 1000000000
```

### Consultar Balance
```bash
cast call 0x130c613A42DB065b09C68DD685f15af14d7F0B1C \
  "getUserBalance(address,address)" [USER] [TOKEN]
```

### Ver Precio ETH
```bash
cast call 0x130c613A42DB065b09C68DD685f15af14d7F0B1C "getEthUsdPrice()"
```

## 🔒 Seguridad

### Patrones Implementados
- ✅ Checks-Effects-Interactions
- ✅ ReentrancyGuard
- ✅ Access Control
- ✅ SafeERC20
- ✅ Validación de oráculos

### Limitaciones Conocidas
1. **Volatilidad de ETH**: El banco garantiza valor en USD, no cantidad de ETH. Si ETH sube de precio, el usuario recibirá menos ETH al retirar el mismo saldo USD.
2. **Asunción de decimales**: Actualmente asume 6 decimales para tokens ERC-20. Solo agregar tokens compatibles.
3. **Sin mecanismo de pausa**: No implementado por simplicidad, pero recomendable para producción.

## 👤 Autor

**Natalia Avila**  
GitHub: [@Natalia-dev-web3](https://github.com/Natalia-dev-web3)

---

**Proyecto**: Ethereum Developer Pack - Módulo 3 - Examen Final  
**Fecha**: Octubre 2025
