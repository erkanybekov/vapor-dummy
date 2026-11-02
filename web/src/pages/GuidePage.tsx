import { useState, type ReactNode } from 'react'
import { Link } from 'react-router'
// The Swift shown here is the real, checked code: it compiles in Swift 6 with
// MainActor default isolation (as in ios/) and was run against this server.
import chatClientSwift from '../guide/ChatClient.swift?raw'
import chatViewSwift from '../guide/ChatView.swift?raw'
import firstStepsSwift from '../guide/first-steps.swift?raw'
import { CheckIcon, CopyIcon } from '../ui/icons'

/**
 * The part of `source` from the line containing `from` up to (not including) the
 * line containing `to`, with the common indentation removed.
 */
function slice(source: string, from: string, to?: string): string {
  const lines = source.split('\n')
  const start = lines.findIndex((line) => line.includes(from))
  const end = to ? lines.findIndex((line, i) => i > start && line.includes(to)) : lines.length
  const picked = lines.slice(start, end === -1 ? lines.length : end)
  while (picked.length > 0 && !picked.at(-1)?.trim()) picked.pop()
  const indent = Math.min(...picked.filter((line) => line.trim()).map((line) => line.length - line.trimStart().length))
  return picked.map((line) => line.slice(indent)).join('\n')
}

function Code({ code, label }: { code: string; label?: string }) {
  const [copied, setCopied] = useState(false)
  const copy = () => {
    void navigator.clipboard.writeText(code).then(() => {
      setCopied(true)
      setTimeout(() => setCopied(false), 1500)
    })
  }
  return (
    <>
      {label && <span className="code-label">{label}</span>}
      <div className="code-block">
        <pre>
          <code>{code}</code>
        </pre>
        <button className="copy" onClick={copy} aria-label="Скопировать код">
          {copied ? <CheckIcon size={14} /> : <CopyIcon size={14} />}
          {copied ? 'Скопировано' : 'Копировать'}
        </button>
      </div>
    </>
  )
}

function Step({ id, n, title, children }: { id: string; n?: number; title: string; children: ReactNode }) {
  return (
    <section id={id} className="card guide-step">
      <h3>
        {n !== undefined && <span className="step-number">{n}</span>}
        {title}
      </h3>
      {children}
    </section>
  )
}

const Check = ({ children }: { children: ReactNode }) => (
  <div className="check">
    <strong>Проверь себя.</strong> {children}
  </div>
)

const Pitfall = ({ children }: { children: ReactNode }) => (
  <div className="pitfall">
    <strong>Грабли.</strong> {children}
  </div>
)

const TOC: [string, string][] = [
  ['how', 'Как устроен WebSocket'],
  ['protocol', 'Протокол учебного чата'],
  ['connect', '1. Подключиться'],
  ['receive', '2. Слушать сообщения'],
  ['codable', '3. Протокол на Codable'],
  ['send', '4. Отправлять'],
  ['alive', '5. Живо ли соединение'],
  ['reconnect', '6. Обрывы и переподключение'],
  ['lifecycle', '7. Жизненный цикл приложения'],
  ['architecture', '8. Архитектура в SwiftUI'],
  ['code', 'Итоговый код'],
  ['checklist', 'Чек-лист best practices'],
  ['homework', 'Домашка'],
]

const handshake = `iPhone                                         Vapor
  │  GET /api/v1/chat/ws?room=general              │
  │  Upgrade: websocket                            │
  │  Authorization: Bearer …                       │
  │ ─────────────────────────────────────────────▶ │
  │ ◀───────────────────── 101 Switching Protocols │  дальше это уже не HTTP
  │ ◀── {"type":"welcome", …}                      │  сервер пишет первым
  │ ──▶ {"type":"send","clientId":"…","text":"Hi"} │
  │ ◀── {"type":"message", …}                      │  всем в комнате, и тебе
  │ ◀── {"type":"typing", …}                       │
  │ ◀─▶ ping / pong                                │  раз в 20 с`

const messageExample = `{
  "type": "message",
  "message": {
    "seq": 42,
    "room": "general",
    "author": { "id": "7E32C1D4-…", "username": "erlan" },
    "text": "Привет",
    "sentAt": "2026-10-27T18:05:11Z",
    "clientId": "B1C0…"
  }
}`

const curlLogin = (origin: string) =>
  `curl -s -X POST ${origin}/api/v1/auth/login \\
  -H 'Content-Type: application/json' \\
  -d '{"email":"ТВОЙ_EMAIL","password":"ТВОЙ_ПАРОЛЬ"}'`

const sendSnippet = `let frame = ClientFrame.send(clientId: UUID().uuidString, text: "Привет из Swift")
let data = try JSONEncoder().encode(frame)
// Только текстовые кадры: бинарные сервер отклонит.
try await task.send(.string(String(decoding: data, as: UTF8.self)))`

const decodeSnippet = `let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601

case .string(let text):
    do {
        let event = try decoder.decode(ServerEvent.self, from: Data(text.utf8))
        print("←", event)
    } catch {
        print("непонятный кадр:", error)   // не роняем цикл из-за одного кадра
    }`

const integrationSnippet = `// ServerEnvironment.swift, рядом с signalingURL
static var chatURL: URL {
    var components = URLComponents(url: apiURL.appending(path: "chat/ws"), resolvingAgainstBaseURL: false)!
    components.scheme = components.scheme == "https" ? "wss" : "ws"
    return components.url!
}

// AppModel.swift: один ChatClient на приложение, а не на каждый показ экрана
let chat = ChatClient(url: ServerEnvironment.chatURL) { [api] forceRefresh in
    try await api.accessToken(forceRefresh: forceRefresh)
}

// Где-то в навигации
NavigationStack { ChatView(chat: model.chat) }`

export function GuidePage() {
  const origin = location.origin
  const wsOrigin = origin.replace(/^http/, 'ws')

  return (
    <div className="page guide">
      <div className="page-header">
        <h1>WebSocket на iOS: от подключения до продакшена</h1>
      </div>
      <p className="guide-intro">
        Пишем на Swift клиент <Link to="/chat">учебного чата</Link>: <code>URLSessionWebSocketTask</code>, протокол на{' '}
        <code>Codable</code>, переподключение, жизненный цикл приложения. Держи{' '}
        <Link to="/chat">чат</Link> открытым во второй вкладке: в блоке «Кадры WebSocket» видно всё, что ходит по сокету.
      </p>

      <section className="card">
        <h2>Содержание</h2>
        <ul className="guide-toc">
          {TOC.map(([id, title]) => (
            <li key={id}>
              <a href={`#${id}`}>{title}</a>
            </li>
          ))}
        </ul>
      </section>

      <Step id="how" title="Как устроен WebSocket">
        <p>
          В REST клиент всегда спрашивает первым: запрос → ответ → тишина. Сервер не может сам сказать «тебе написали».
          Можно спрашивать каждые пару секунд (polling), но это задержки и пустая нагрузка.
        </p>
        <p>
          WebSocket начинается как обычный HTTP-запрос с заголовком <code>Upgrade: websocket</code>. Сервер отвечает{' '}
          <code>101 Switching Protocols</code>, и с этого момента то же TCP-соединение становится двусторонним каналом:
          обе стороны в любой момент шлют друг другу <b>кадры</b> (frames).
        </p>
        <Code code={handshake} />
        <h4>Какие бывают кадры</h4>
        <ul>
          <li>
            <b>text</b> — строка. У нас в ней всегда JSON с полем <code>type</code>.
          </li>
          <li>
            <b>binary</b> — байты (картинки, свои бинарные протоколы). Наш чат их не принимает.
          </li>
          <li>
            <b>ping / pong</b> — служебные «ты жив?» — «жив». <code>URLSession</code> отвечает на ping сам.
          </li>
          <li>
            <b>close</b> — вежливое закрытие с кодом: <code>1000</code> — нормально, <code>1001</code> — ухожу,{' '}
            <code>4000–4999</code> — коды приложения. Если связь просто пропала, close-кадра не будет вовсе.
          </li>
        </ul>
        <h4>Когда он нужен</h4>
        <p>
          Когда сервер должен сообщать о событиях сам: чаты, сигналинг звонков (у тебя уже есть{' '}
          <code>/api/v1/calls/ws</code>), «печатает…», онлайн-статусы, совместное редактирование, игры. Загрузить список
          или отправить форму — это по-прежнему REST. Хорошее правило: <b>живое — через сокет, история — через REST</b>.
          Учебный чат так и устроен.
        </p>
      </Step>

      <Step id="protocol" title="Протокол учебного чата">
        <div className="table-wrap">
          <table className="protocol-table">
            <tbody>
              <tr>
                <th>Адрес</th>
                <td>
                  <code>{wsOrigin}/api/v1/chat/ws</code>
                  <br />
                  локально <code>ws://localhost:8080/api/v1/chat/ws</code>, прод{' '}
                  <code>wss://vapor-calls.onrender.com/api/v1/chat/ws</code>
                </td>
              </tr>
              <tr>
                <th>Токен</th>
                <td>
                  Заголовок <code>Authorization: Bearer &lt;accessToken&gt;</code>. Браузер заголовки на сокет ставить не
                  умеет, поэтому веб шлёт <code>?token=</code>, а iOS лучше заголовком: URL попадает в логи.
                </td>
              </tr>
              <tr>
                <th>
                  <code>?room=</code>
                </th>
                <td>
                  Комната, по умолчанию <code>general</code>. Латиница в нижнем регистре, цифры, дефис, до 32 символов.
                </td>
              </tr>
              <tr>
                <th>
                  <code>?after=</code>
                </th>
                <td>
                  <code>seq</code> последнего сообщения, которое у тебя уже есть. Тогда <code>welcome</code> принесёт
                  только пропущенное.
                </td>
              </tr>
              <tr>
                <th>Отказ</th>
                <td>
                  До переключения на WebSocket сервер может ответить <code>401</code> (нет или плохой токен) или{' '}
                  <code>400</code> (плохая комната).
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <h4>Ты → сервер</h4>
        <div className="table-wrap">
          <table className="protocol-table">
            <thead>
              <tr>
                <th>type</th>
                <th>Поля</th>
                <th>Зачем</th>
              </tr>
            </thead>
            <tbody>
              <tr>
                <td>
                  <code>send</code>
                </td>
                <td>
                  <code>clientId</code>, <code>text</code>
                </td>
                <td>
                  Сообщение, 1–2000 символов. <code>clientId</code> — твой UUID для этого сообщения.
                </td>
              </tr>
              <tr>
                <td>
                  <code>typing</code>
                </td>
                <td>
                  <code>isTyping</code>
                </td>
                <td>
                  «Печатаю». Пока человек печатает, повторяй <code>true</code> раз в 3 с; <code>false</code> — когда
                  стёр текст.
                </td>
              </tr>
              <tr>
                <td>
                  <code>ping</code>
                </td>
                <td>—</td>
                <td>
                  Ответ <code>pong</code>. Нужен браузеру; на iOS есть настоящий ping-кадр.
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <h4>Сервер → тебе</h4>
        <div className="table-wrap">
          <table className="protocol-table">
            <thead>
              <tr>
                <th>type</th>
                <th>Поля</th>
                <th>Когда</th>
              </tr>
            </thead>
            <tbody>
              <tr>
                <td>
                  <code>welcome</code>
                </td>
                <td>
                  <code>room</code>, <code>you</code>, <code>online</code>, <code>messages</code>, <code>hasMore</code>
                </td>
                <td>
                  Всегда первым. <code>messages</code> — последние 50 (или пропущенные после <code>after</code>), от
                  старых к новым. <code>hasMore</code> — есть более старые.
                </td>
              </tr>
              <tr>
                <td>
                  <code>message</code>
                </td>
                <td>
                  <code>message</code>
                </td>
                <td>Новое сообщение в комнате, включая твоё собственное: это и есть подтверждение доставки.</td>
              </tr>
              <tr>
                <td>
                  <code>presence</code>
                </td>
                <td>
                  <code>online</code>
                </td>
                <td>Кто-то пришёл или ушёл. Весь список целиком.</td>
              </tr>
              <tr>
                <td>
                  <code>typing</code>
                </td>
                <td>
                  <code>user</code>, <code>isTyping</code>
                </td>
                <td>
                  Кто-то печатает. Если повтора нет 6 с — считай, что перестал.
                </td>
              </tr>
              <tr>
                <td>
                  <code>error</code>
                </td>
                <td>
                  <code>code</code>, <code>message</code>, <code>clientId?</code>
                </td>
                <td>
                  Кривой кадр (<code>bad_request</code>), слишком часто (<code>rate_limited</code>), плохое сообщение (
                  <code>invalid_message</code>). С <code>clientId</code> — про конкретное твоё сообщение.
                </td>
              </tr>
              <tr>
                <td>
                  <code>pong</code>
                </td>
                <td>—</td>
                <td>
                  Ответ на <code>ping</code>.
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <Code label="Так выглядит кадр message" code={messageExample} />
        <p>
          <b>История выше</b> — обычный REST: <code>GET /api/v1/chat/rooms/general/messages?before=42</code> →{' '}
          <code>{'{ messages, hasMore }'}</code>. <b>Лимиты:</b> 20 кадров залпом, дальше 5 в секунду; кадр до 16 КБ;
          сервер пингует раз в 20 с и закрывает тех, кто не отвечает.
        </p>
      </Step>

      <Step id="connect" n={1} title="Подключиться">
        <p>Начнём не с приложения, а с одного Swift-файла: он запускается прямо из терминала. Сначала токен:</p>
        <Code code={curlLogin(origin)} />
        <p>
          Скопируй <code>accessToken</code> из ответа (он живёт час). Теперь начало файла <code>first-steps.swift</code>:
        </p>
        <Code code={slice(firstStepsSwift, 'import Foundation', 'do {')} />
        <ul>
          <li>
            <code>webSocketTask(with:)</code> только создаёт задачу, <code>resume()</code> запускает рукопожатие.
          </li>
          <li>
            <code>resume()</code> ничего не возвращает и не бросает ошибок. Неверный токен или выключенный сервер ты
            увидишь только при первом чтении или отправке.
          </li>
          <li>
            Запускать пока рано: без цикла приёма скрипт сразу завершится, и соединение закроется вместе с ним.
          </li>
        </ul>
        <Pitfall>
          <code>ws://</code> — без шифрования, как <code>http://</code>. Симулятор ходит на <code>localhost</code> твоего
          Mac без проблем, а на настоящем iPhone App Transport Security не пустит <code>ws://</code> по IP — используй{' '}
          <code>wss://vapor-calls.onrender.com</code>.
        </Pitfall>
      </Step>

      <Step id="receive" n={2} title="Слушать сообщения">
        <p>
          <code>try await task.receive()</code> ждёт <b>один</b> кадр и возвращает <code>.string</code> или{' '}
          <code>.data</code>. Чтобы слушать постоянно, зови его в цикле. Когда соединение закрывается (или так и не
          открылось), <code>receive()</code> бросает ошибку — это единственный надёжный сигнал «всё, сокета нет».
        </p>
        <Code label="first-steps.swift целиком" code={firstStepsSwift.trimEnd()} />
        <p>
          В <code>catch</code> полезно посмотреть <code>task.response</code>: это HTTP-ответ на рукопожатие, и там виден{' '}
          <code>401</code>, если токен не подошёл. Браузер такого не умеет, а iOS умеет — пользуйся.
        </p>
        <Check>
          Запусти <code>swift first-steps.swift</code>. Первым придёт <code>welcome</code>. Открой <Link to="/chat">чат</Link>{' '}
          в браузере: ты появишься в «Онлайн», а в терминале — <code>presence</code>. Напиши в браузере — увидишь{' '}
          <code>message</code>. Подставь неверный токен — получишь <code>HTTP-статус рукопожатия: 401</code>.
        </Check>
      </Step>

      <Step id="codable" n={3} title="Протокол на Codable">
        <p>
          Сравнивать строки руками быстро надоест. Каждый кадр — JSON с полем <code>type</code>, а это в Swift ложится на{' '}
          <code>enum</code> с associated values: читаем <code>type</code> и решаем, что декодировать дальше.
        </p>
        <Code label="Типы протокола (начало итогового ChatClient.swift)" code={slice(chatClientSwift, 'import Foundation', '// MARK: - Клиент')} />
        <ul>
          <li>
            <code>case unknown(String)</code> — защита на будущее: сервер добавит новый тип кадра, а старая версия
            приложения из App Store не упадёт, а просто его проигнорирует.
          </li>
          <li>
            Даты приходят строкой ISO 8601, поэтому декодеру нужен <code>.iso8601</code>.
          </li>
          <li>Ошибка разбора одного кадра не должна обрывать цикл приёма.</li>
        </ul>
        <Code label="В цикле из шага 2" code={decodeSnippet} />
      </Step>

      <Step id="send" n={4} title="Отправлять">
        <Code code={sendSnippet} />
        <p>Как сделать отправку надёжной:</p>
        <ol>
          <li>
            <b>Жди <code>welcome</code></b>: это сигнал «можно говорить», заодно из него узнаёшь, кто ты.
          </li>
          <li>
            <b>Каждому сообщению — свой <code>clientId</code></b> (UUID).
          </li>
          <li>
            <b>Оптимистичный UI</b>: сразу показывай сообщение с пометкой «отправляется…».
          </li>
          <li>
            <b>Подтверждение — эхо.</b> Сервер присылает твоё же сообщение обратно уже с <code>seq</code> и тем же{' '}
            <code>clientId</code>: заменяй им черновик.
          </li>
          <li>
            <b>Ошибка с <code>clientId</code></b> — помечай это сообщение «не отправлено» и предлагай повторить.
          </li>
          <li>
            <b>Повтор безопасен</b>: если отправить тот же <code>clientId</code> ещё раз, сервер не создаст дубль, а
            просто пришлёт подтверждение.
          </li>
        </ol>
        <Check>Отправь сообщение из Swift — оно появится в браузере. В «Кадрах» видно оба направления.</Check>
      </Step>

      <Step id="alive" n={5} title="Живо ли соединение">
        <p>
          Телефон сменил Wi-Fi на LTE, роутер забыл соединение — а TCP может не замечать этого минутами. Сокет вроде
          открыт, но никуда не ведёт. Поэтому обе стороны регулярно пингуют друг друга:
        </p>
        <ul>
          <li>
            Сервер шлёт ping раз в 20 с; <code>URLSession</code> отвечает pong сам, тебе ничего делать не нужно.
          </li>
          <li>
            Клиент тоже пингует, через <code>sendPing</code>. Не пришёл pong до следующего пинга — рвём соединение сами
            и переподключаемся.
          </li>
        </ul>
        <Code label="Из ChatClient.swift" code={slice(chatClientSwift, '/// Раз в 20 с ping', '// MARK: Входящие')} />
        <p>
          Браузер ping-кадры отправлять не умеет, поэтому в протоколе есть JSON <code>{'{"type":"ping"}'}</code> — его
          использует веб-клиент.
        </p>
      </Step>

      <Step id="reconnect" n={6} title="Обрывы и переподключение">
        <p>Обрыв — это норма, а не исключение: метро, лифт, перезапуск сервера при деплое. Правила хорошего клиента:</p>
        <ol>
          <li>
            <b>Пауза растёт</b>: 0,5 → 1 → 2 → 4 … до 30 с, и <b>со случайной добавкой</b>. Иначе после перезапуска
            сервера все клиенты постучатся в одну и ту же секунду.
          </li>
          <li>
            <b>Счётчик сбрасывается</b> после успешного <code>welcome</code>.
          </li>
          <li>
            <b>Поколение (<code>generation</code>)</b>: у каждого подключения свой номер. Старый цикл приёма видит, что он
            уже не главный, и ничего не трогает.
          </li>
          <li>
            <b><code>?after=</code> последнего <code>seq</code></b> — сервер пришлёт только пропущенное. Сообщения
            сортируй и склеивай по <code>seq</code>: одно и то же может прийти дважды.
          </li>
          <li>
            <b>Дыра</b>: если при <code>after</code> пришёл <code>hasMore: true</code>, пропущено больше, чем сервер
            отдал. Замени список целиком.
          </li>
          <li>
            <b>Очередь неотправленного</b>: после <code>welcome</code> досылай все свои черновики с теми же{' '}
            <code>clientId</code>.
          </li>
          <li>
            <b><code>401</code> → обнови токен</b> и подключись снова. Но не обновляй токен на каждой попытке:
            refresh-токены одноразовые и с лимитом.
          </li>
        </ol>
        <Code label="Из ChatClient.swift" code={slice(chatClientSwift, '    private func connect()', '    private func transmit')} />
        <Pitfall>
          Реальная история из этого проекта. После ответа <code>401</code> на рукопожатие <code>URLSession</code>{' '}
          переиспользует то же TCP-соединение для следующей попытки, а сервер, однажды увидев там{' '}
          <code>Upgrade</code>, больше не читает HTTP на нём — клиент висел в «подключении» вечно. Починили на сервере:
          отказ в рукопожатии теперь отвечает <code>Connection: close</code>. Мораль: тестируй путь с протухшим
          токеном, он ломается чаще всего.
        </Pitfall>
        <Check>
          Подключись из Swift, затем останови локальный сервер (<code>Ctrl+C</code>) и запусти снова: клиент сам
          переподключится. Пока он отключён, напиши из браузера — после переподключения сообщения придут в{' '}
          <code>welcome</code>.
        </Check>
      </Step>

      <Step id="lifecycle" n={7} title="Жизненный цикл приложения">
        <ul>
          <li>
            <b>Фон.</b> Через несколько секунд после сворачивания iOS замораживает приложение, и сокет тихо умирает.
            Поэтому на <code>.background</code> закрываем сами, на <code>.active</code> — подключаемся (и сразу
            догружаем пропущенное через <code>after</code>).
          </li>
          <li>
            <b>Смена сети.</b> <code>NWPathMonitor</code> сообщает, что сеть вернулась, — подключаемся сразу, не дожидаясь
            паузы.
          </li>
          <li>
            <b>Когда приложение закрыто</b>, сокета нет вообще. Сообщения в этот момент доставляют push-уведомления
            (APNs) — это следующий этап, когда будет аккаунт Apple Developer.
          </li>
        </ul>
        <Code label="Из ChatView.swift" code={slice(chatViewSwift, '// В фоне iOS', '    private func send()')} />
        <Code label="Из ChatClient.start()" code={slice(chatClientSwift, '        let monitor = NWPathMonitor()', '        connect()')} />
      </Step>

      <Step id="architecture" n={8} title="Архитектура в SwiftUI">
        <ul>
          <li>
            <b>Один владелец сокета.</b> <code>ChatClient</code> создаётся один раз (в <code>AppModel</code>), экраны его
            только читают. Не открывай сокет в <code>body</code> или <code>onAppear</code> каждого экрана.
          </li>
          <li>
            <b><code>@MainActor @Observable</code>.</b> Всё состояние живёт на главном потоке, SwiftUI перерисовывается
            сам, а Swift 6 гарантирует, что гонок нет. <code>await task.receive()</code> не блокирует главный поток — он
            просто ждёт.
          </li>
          <li>
            <b>Токен — через замыкание</b> <code>token(forceRefresh:)</code>: клиент чата не знает, откуда токены берутся.
          </li>
          <li>
            <b>Логи.</b> Пиши кадры в лог (в VaporCalls уже есть Pulse), но не токены.
          </li>
        </ul>
        <Code label="Как встроить в VaporCalls" code={integrationSnippet} />
      </Step>

      <Step id="code" title="Итоговый код">
        <p>
          Это рабочий код, а не набросок: он компилируется в Swift 6 с изоляцией <code>MainActor</code> по умолчанию (как в
          VaporCalls) и прогнан против сервера. Проверены подключение, эхо, «печатает», догрузка через{' '}
          <code>after</code>, отправка из очереди после переподключения и <code>401</code> → новый токен.
        </p>
        <Code label="ChatClient.swift" code={chatClientSwift.trimEnd()} />
        <Code label="ChatView.swift" code={chatViewSwift.trimEnd()} />
      </Step>

      <Step id="checklist" title="Чек-лист best practices">
        <ul className="checklist">
          <li>
            В продакшене <code>wss://</code>; токен в заголовке, а не в URL.
          </li>
          <li>
            Отправлять только после <code>welcome</code>.
          </li>
          <li>
            Каждый кадр — JSON с <code>type</code>; неизвестные типы игнорировать.
          </li>
          <li>
            У каждого исходящего сообщения свой <code>clientId</code>; подтверждение — эхо; повтор безопасен.
          </li>
          <li>
            Сортировать и убирать дубли по <code>seq</code>.
          </li>
          <li>
            При переподключении — <code>?after=</code>; дыра → заменить список.
          </li>
          <li>Пауза растёт экспоненциально, со случайной добавкой; после успеха — сброс.</li>
          <li>Пинг с таймаутом: мёртвое соединение рвём сами.</li>
          <li>
            <code>401</code> → обновить токен, но не на каждую попытку.
          </li>
          <li>
            В фоне закрывать, на переднем плане открывать; <code>NWPathMonitor</code> — сразу при возврате сети.
          </li>
          <li>
            Один владелец сокета, состояние на <code>MainActor</code>.
          </li>
          <li>История — через REST, живое — через сокет.</li>
          <li>
            Не спамить: <code>typing</code> не чаще раза в 3 с.
          </li>
        </ul>
      </Step>

      <Step id="homework" title="Домашка">
        <ol>
          <li>
            Кнопка «Показать более ранние»: <code>GET /api/v1/chat/rooms/general/messages?before=</code>{' '}
            <i>seq первого сообщения</i>.
          </li>
          <li>
            Баннер «Нет связи» по <code>chat.state</code> и кнопка «Повторить» у неотправленных.
          </li>
          <li>Счётчик непрочитанных, пока экран чата закрыт.</li>
          <li>Добавь в VaporCalls вкладку «Чат» и поговори сам с собой: iPhone ↔ браузер.</li>
          <li>
            Подумай, как сделать «прочитано»: какой кадр добавить и кому его рассылать. Сервер в твоих руках —{' '}
            <code>Sources/hello/Domain/UseCases/ChatHub.swift</code>.
          </li>
        </ol>
      </Step>
    </div>
  )
}
