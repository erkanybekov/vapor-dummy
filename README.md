# 🚀 Vapor Auth API

Чистый, профессиональный Vapor backend с JWT аутентификацией.

## ⚡ Быстрый Старт

```bash
# 1. Запустить PostgreSQL
docker-compose up -d

# 2. Запустить приложение  
swift run
```

## 🔒 Middleware - Что Это?

**Middleware** = промежуточный слой между запросом и ответом.

```swift
Request → Middleware → Controller → Response
```

**Зачем нужен:**
- **Аутентификация** - проверяет токены
- **Авторизация** - проверяет права доступа  
- **Логирование** - записывает запросы
- **Валидация** - проверяет данные

### Наш AuthMiddleware:
```swift
// JWTBearerAuthenticator - проверяет JWT токен
// UserAuthenticator - требует авторизованного пользователя
```

## 🛣️ AuthController - Как Добавить Routes

### Текущие маршруты:
```swift
POST /api/v1/auth/login     // Вход
POST /api/v1/auth/register  // Регистрация  
POST /api/v1/auth/refresh   // Обновить токен
POST /api/v1/auth/logout    // Выход (защищён)
GET  /api/v1/auth/me        // Текущий пользователь (защищён)
```

### Добавить новый маршрут:

**1. В AuthController добавить функцию:**
```swift
func newEndpoint(_ req: Request) async throws -> SomeResponse {
    // Ваша логика
}
```

**2. В boot() зарегистрировать:**
```swift
// Публичный маршрут
auth.post("new-endpoint", use: newEndpoint)

// Защищённый маршрут  
protected.get("protected-endpoint", use: newEndpoint)
```

### Структура проекта:
```
Sources/hello/
├── Domain/           # Бизнес-логика
├── Infrastructure/   # DB, Services
└── Presentation/     # API слой
    ├── Controllers/  # AuthController
    ├── DTOs/        # Request/Response
    └── Middleware/  # Аутентификация
```

## 📡 API Endpoints

### 🔐 Authentication
```
POST /api/v1/auth/register    # Регистрация
POST /api/v1/auth/login       # Вход  
POST /api/v1/auth/refresh     # Обновить токен
POST /api/v1/auth/logout      # Выход (защищён)
GET  /api/v1/auth/me          # Текущий пользователь (защищён)
```

### ✅ Todo CRUD

**Все Todo endpoints требуют авторизации (Bearer Token)**

#### Получить все задачи
```http
GET /api/v1/todos
Authorization: Bearer <access_token>
```

**Response:**
```json
{
  "todos": [
    {
      "id": "uuid",
      "title": "Изучить Vapor",
      "description": "Создать API с чистой архитектурой",
      "completed": false,
      "createdAt": "2025-01-17T01:00:00Z",
      "updatedAt": "2025-01-17T01:00:00Z"
    }
  ],
  "count": 1
}
```

#### Создать задачу
```http
POST /api/v1/todos
Authorization: Bearer <access_token>
Content-Type: application/json

{
  "title": "Новая задача",
  "description": "Описание задачи (опционально)"
}
```

#### Получить задачу по ID
```http
GET /api/v1/todos/{id}
Authorization: Bearer <access_token>
```

#### Обновить задачу
```http
PUT /api/v1/todos/{id}
Authorization: Bearer <access_token>
Content-Type: application/json

{
  "title": "Обновлённое название",
  "description": "Новое описание",
  "completed": true
}
```

#### Переключить статус задачи
```http
PATCH /api/v1/todos/{id}/toggle
Authorization: Bearer <access_token>
```

#### Удалить задачу
```http
DELETE /api/v1/todos/{id}
Authorization: Bearer <access_token>
```

### 💡 Особенности Todo API

- **Безопасность**: Все Todo принадлежат конкретному пользователю
- **Валидация**: Заголовок max 200 символов, описание max 1000
- **Сортировка**: Задачи возвращаются по дате создания (новые первые)
- **Ошибки**: 400/401/403/404 с понятными сообщениями

### 🔍 Health Check
```http
GET /api/v1/health    # Статус API и БД
GET /api/v1/          # Приветствие API
```

## 📹 Видеозвонки (WebRTC)

Свой FaceTime: звонок пользователю по email, а звонок **на свой же email** звонит на твои другие устройства.

### Как это устроено

```
 iPhone ──┐  WebSocket (JSON)   ┌──────────────┐   WebSocket   ┌── Mac
          ├───── сигналинг ────▶│ Vapor CallHub │◀──────────────┤
          │                     └──────────────┘               │
          └════════ аудио/видео P2P (WebRTC, SRTP) ════════════┘
                     (через TURN, если P2P невозможен)
```

- **Сервер не трогает медиа.** Он только знакомит устройства: кто онлайн, кому звонить, и пересылает SDP offer/answer + ICE-кандидаты. Видео идёт напрямую между устройствами.
- **STUN** (`stun.l.google.com`) помогает узнать публичный адрес. **TURN** ретранслирует медиа, когда прямое соединение невозможно (мобильный интернет за CGNAT, строгий NAT). Без TURN часть звонков между разными сетями не соединится.
- `CallHub` — actor со стейт-машиной звонка: `ringing → active → ended`. Всё состояние в памяти процесса → **один инстанс**. Для нескольких инстансов нужна общая шина (Redis pub/sub).

### Надёжность

| Ситуация | Что делает сервер |
|---|---|
| Несколько устройств у получателя | Звонит на все свободные; ответил один — остальные получают `answered_elsewhere` |
| Никто не ответил | `timeout` через 30 с (`CALL_RING_TIMEOUT_SECONDS`) |
| Сеть моргнула посреди звонка (Wi-Fi → LTE) | Ждёт переподключения 15 с (`CALL_RECONNECT_GRACE_SECONDS`), потом `call.resumed` → новая WebRTC-сессия |
| Новый сокет с того же устройства | Старый закрывается, звонок продолжается на новом |
| Сокет «завис» без FIN | WebSocket ping каждые 15 с; нет pong — сокет закрывается |
| Флуд сообщениями | Token bucket на соединение (60 burst, 20/с) |
| Порядок сигналов | Сообщения сокета обрабатываются строго по очереди (offer раньше кандидатов) |
| БД медленная/упала | История пишется в фоне, сигналинг не ждёт БД |

### Эндпоинты

```
GET /api/v1/calls/ws?token=<access>&deviceId=<id>&deviceName=<name>   # WebSocket
GET /api/v1/calls/ice-servers    # STUN/TURN для RTCPeerConnection (Bearer)
GET /api/v1/calls/history        # история звонков (Bearer), ?limit=50
```

Нативные клиенты могут передавать токен в `Authorization: Bearer`, браузер — только в `?token=`.
`deviceId` — стабильный id устройства (на iOS — `identifierForVendor`): по нему сервер узнаёт переподключение и восстанавливает звонок.
Клиент начинает слать сообщения только после `hello`. Код закрытия `4000` означает «вытеснен новым подключением этого же устройства», переподключаться не нужно.

### Протокол (JSON по WebSocket)

Клиент → сервер:
```jsonc
{"type":"call.invite","calleeEmail":"me@example.com","video":true}   // или calleeId
{"type":"call.accept","callId":"…"}
{"type":"call.decline","callId":"…"}
{"type":"call.hangup","callId":"…"}
{"type":"call.signal","callId":"…","signal":{"kind":"offer","sdp":"…"}}
{"type":"call.signal","callId":"…","signal":{"kind":"candidate","candidate":{"candidate":"…","sdpMid":"0","sdpMLineIndex":0}}}
{"type":"ping"}
```

Сервер → клиент: `hello` (ICE-серверы), `presence` (твои устройства онлайн), `call.ringing`, `call.incoming`,
`call.accepted` (`role: caller` создаёт offer), `call.signal`, `call.reconnecting`, `call.resumed`, `call.ended` (`reason`), `error`, `pong`.

Последовательность звонка:
```
Mac                      Server                    iPhone
 │── call.invite ──────────▶│                          │
 │◀── call.ringing ─────────│── call.incoming ────────▶│
 │                          │◀───────── call.accept ───│
 │◀── call.accepted(caller)─│── call.accepted(callee) ▶│
 │── signal(offer) ────────▶│── signal(offer) ────────▶│
 │◀── signal(answer) ───────│◀──────── signal(answer) ─│
 │◀═══════════ ICE candidates в обе стороны ══════════▶│
 │◀═══════════════ медиа P2P ═════════════════════════▶│
```

### Позвонить себе с другого устройства

1. `swift run` и открыть `http://localhost:8080/call.html` на Mac, войти.
2. Камера в браузере работает только по HTTPS (или на localhost), поэтому для телефона нужен туннель:
   ```bash
   cloudflared tunnel --url http://localhost:8080
   ```
3. Открыть выданный `https://….trycloudflare.com/call.html` на iPhone, войти **тем же** аккаунтом.
4. В «Позвонить» оставить свой email → 📹 Видео. Телефон зазвонит.

### TURN (для звонков между разными сетями)

```bash
# coturn: static-auth-secret=<секрет>, use-auth-secret
TURN_URLS="turn:turn.example.com:3478?transport=udp,turns:turn.example.com:5349"
TURN_SECRET="<тот же секрет>"            # сервер выдаёт временные креды (HMAC-SHA1)
# или статичные креды у хостинг-провайдера TURN:
TURN_USERNAME=…  TURN_CREDENTIAL=…
```

## 🔒 CORS Configuration

API использует безопасную конфигурацию CORS:

### Development
- Разрешены localhost и dev порты

### Production  
- **Whitelist конкретных доменов** через `CORS_ALLOWED_ORIGINS`
- Формат: `https://domain1.com,https://domain2.com`
- Fallback: только HTTPS соединения

### Security Features
- ❌ Никаких wildcard `*` origins
- ✅ Только HTTPS в production
- ✅ Строгий whitelist доменов
- ✅ Защита от CSRF атак
DATABASE_USERNAME=vapor_username
DATABASE_PASSWORD=vapor_password
DATABASE_NAME=vapor_database

JWT_SECRET=your-super-secret-jwt-key-here
JWT_ISSUER=your-app-name
JWT_AUDIENCE=your-app-users
```

### 4. Database Setup

#### Option A: Using Docker (Recommended)

Start PostgreSQL using Docker Compose:

```bash
docker-compose up -d
```

This will start PostgreSQL on port 5432 with the credentials from your `.env` file.

#### Option B: Local PostgreSQL

If you have PostgreSQL installed locally, create a database:

```sql
CREATE DATABASE vapor_database;
CREATE USER vapor_username WITH PASSWORD 'vapor_password';
GRANT ALL PRIVILEGES ON DATABASE vapor_database TO vapor_username;
```

### 5. Run Database Migrations

The app will automatically run migrations on startup, creating the necessary tables:
- `users` - User accounts
- `revoked_tokens` - Token revocation tracking

## 🏃 Running the Application

### Development Mode

```bash
swift run
```

The server will start on `http://localhost:8080`

### Production Build

```bash
swift build -c release
.build/release/hello
```

### Using Docker

Build and run with Docker:

```bash
docker build -t vapor-auth-api .
docker run -p 8080:8080 vapor-auth-api
```

## 📦 Adding Dependencies

To add new dependencies, edit `Package.swift`:

```swift
dependencies: [
    // Add your dependency here
    .package(url: "https://github.com/package-url", from: "1.0.0"),
],
targets: [
    .target(
        name: "hello",
        dependencies: [
            // Add the product here
            .product(name: "PackageName", package: "package-name"),
        ]
    ),
]
```

Then update dependencies:

```bash
swift package update
```

## 🔌 API Endpoints

### Base URL
```
http://localhost:8080
```

### Authentication Endpoints

#### 1. Register User
```http
POST /api/auth/register
Content-Type: application/json

{
  "email": "user@example.com",
  "username": "johndoe",
  "password": "SecurePass123"
}
```

**Response:**
```json
{
  "user": {
    "id": "uuid",
    "email": "user@example.com",
    "username": "johndoe",
    "isActive": true,
    "createdAt": "2025-01-14T10:00:00Z",
    "updatedAt": "2025-01-14T10:00:00Z"
  },
  "token": {
    "accessToken": "eyJ...",
    "refreshToken": "eyJ...",
    "expiresIn": 3600
  }
}
```

#### 2. Login
```http
POST /api/auth/login
Content-Type: application/json

{
  "email": "user@example.com",
  "password": "SecurePass123"
}
```

**Response:** Same as registration

#### 3. Refresh Token
```http
POST /api/auth/refresh
Content-Type: application/json

{
  "refreshToken": "eyJ..."
}
```

**Response:**
```json
{
  "accessToken": "eyJ...",
  "refreshToken": "eyJ...",
  "expiresIn": 3600
}
```

#### 4. Get Current User
```http
GET /api/auth/me
Authorization: Bearer <access_token>
```

**Response:**
```json
{
  "id": "uuid",
  "email": "user@example.com",
  "username": "johndoe",
  "isActive": true,
  "createdAt": "2025-01-14T10:00:00Z",
  "updatedAt": "2025-01-14T10:00:00Z"
}
```

#### 5. Logout
```http
POST /api/auth/logout
Authorization: Bearer <access_token>
```

**Response:**
```json
{
  "message": "Successfully logged out"
}
```

### Health Check

```http
GET /health
```

**Response:**
```json
{
  "status": "ok",
  "timestamp": "2025-01-14T10:00:00Z"
}
```

## 🏗️ Project Structure

```
vapor-dummy/
├── Sources/
│   └── hello/
│       ├── Domain/              # Business logic layer
│       │   ├── Entities/        # Domain models
│       │   ├── Protocols/       # Domain interfaces
│       │   └── UseCases/        # Business rules
│       ├── Infrastructure/      # External interfaces
│       │   ├── DI/             # Dependency injection
│       │   ├── Persistence/     # Database layer
│       │   │   ├── Migrations/  # Database migrations
│       │   │   └── Models/      # Database models
│       │   └── Services/        # External services
│       ├── Presentation/        # API layer
│       │   └── Controllers/     # Route handlers
│       ├── configure.swift      # App configuration
│       ├── routes.swift         # Route definitions
│       └── main.swift          # Entry point
├── Tests/                      # Test files
├── Public/                     # Static files
├── Package.swift              # Dependencies
├── docker-compose.yml         # Docker services
└── Dockerfile                 # Container definition
```

## 🔧 Configuration

### JWT Configuration

JWT settings are configured in `configure.swift`:
- **Access Token Expiry**: 1 hour
- **Refresh Token Expiry**: 30 days
- **Algorithm**: HS256

### Database Configuration

Database connection is configured using environment variables:
- Connection pooling enabled
- Automatic migration on startup
- TLS disabled for local development

### Password Requirements

- Minimum 8 characters
- At least one uppercase letter
- At least one lowercase letter
- At least one number

## 🧪 Testing

Run the test suite:

```bash
swift test
```

Run tests with coverage:

```bash
swift test --enable-code-coverage
```

## 🐳 Docker Deployment

### Using Docker Compose (Development)

```bash
docker-compose up
```

This starts:
- PostgreSQL database
- Vapor application

### Production Deployment

Build for production:

```bash
docker build -t vapor-auth-api .
docker run -d \
  -p 8080:8080 \
  --env-file .env \
  --name vapor-api \
  vapor-auth-api
```

## 🔍 Troubleshooting

### Common Issues

#### 1. Database Connection Failed
- Check PostgreSQL is running: `docker ps`
- Verify credentials in `.env`
- Check network connectivity

#### 2. JWT Token Invalid
- Ensure `JWT_SECRET` is set in environment
- Check token hasn't expired
- Verify token format in Authorization header

#### 3. Build Errors
- Clean build: `swift package clean`
- Update dependencies: `swift package update`
- Reset Package.resolved: `rm Package.resolved && swift package resolve`

### Debug Mode

Enable debug logging:

```bash
LOG_LEVEL=debug swift run
```

## 📝 API Documentation

For detailed API documentation with request/response examples, import the following Postman collection:

```json
{
  "info": {
    "name": "Vapor Auth API",
    "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json"
  },
  "item": [
    // Collection items here
  ]
}
```

## 🤝 Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## 📄 License

This project is licensed under the MIT License.

## 🔗 Resources

- [Vapor Documentation](https://docs.vapor.codes)
- [Swift Package Manager](https://swift.org/package-manager/)
- [JWT.io](https://jwt.io)
- [PostgreSQL Documentation](https://www.postgresql.org/docs/)
