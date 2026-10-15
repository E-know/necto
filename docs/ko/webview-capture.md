# WebView 통신 보기

`NectoWebViewCapture`를 쓰면 앱 안 `WKWebView` 페이지가 주고받는 내용을 이미 있는
패널에서 볼 수 있어요.

| 무엇 | 보이는 곳 |
| --- | --- |
| 페이지의 `fetch`와 `XMLHttpRequest` | **Network**, `WebView` 배지와 함께 |
| 페이지가 앱 메시지 핸들러로 보낸 메시지와 그 응답 | **Event Log**, `WebView` 카테고리 |
| 앱이 페이지에서 실행한 JavaScript (`evaluateJavaScript`, `callAsyncJavaScript`) | **Event Log**, `WebView` 카테고리 |

네이티브 코드 한 곳만 바꾸면 돼요. 웹 코드는 바꾸지 않아요. Necto가 실행 중에
각 페이지에 자기 스크립트를 심어요.

> **코딩 에이전트에게.** 앱 저장소에서 [단계](#단계)를 순서대로 따라 적용하세요.
> 웹 코드는 고치지 않아요. HTML, JavaScript, TypeScript를 비롯해 WebView가 불러오는
> 어떤 것도 바꾸지 않아요. 모든 Necto 호출은 `#if DEBUG` 안에 두세요. 마지막에
> [확인하기](#확인하기)와 [끝난 기준](#끝난-기준)을 확인하세요.

## 시작하기 전에

- [setup.md](setup.md)대로 앱에 Necto가 연결되어 있고, 앱 시작 코드에서
  `NectoSDK.start()`를 불러요.
- 의존성은 바꾸지 않아요. `NectoWebViewCapture`는 앱이 이미 링크하는 `NectoSDK`
  product에 들어 있어요. Tuist라면 `.external(name: "NectoSDK")`로 함께 들어오니,
  따로 product를 추가하지 마세요.
- 앱의 페이지가 `WKWebView`에서 돌아요. `SFSafariViewController`와
  `ASWebAuthenticationSession`은 별도 브라우저라서 캡처되지 않아요.

## 단계

### 1. Necto 시작 코드 찾기

앱에서 `NectoSDK.start(`를 검색하세요. 없으면 먼저 [setup.md](setup.md)대로 Necto를
연결한 뒤 이어서 진행하세요.

### 2. 네트워크·이벤트 플러그인을 값으로 두기

`install`에는 캡처한 내용을 받을 플러그인 두 개를 넘겨요. 시작 코드에서 바로
등록하고 있다면 이름을 붙여 주세요.

```swift
// 바꾸기 전
NectoSDK.register(URLSessionNetworkPlugin())
NectoSDK.register(NectoEventsPlugin())

// 바꾼 뒤
let network = URLSessionNetworkPlugin()
let events = NectoEventsPlugin()
NectoSDK.register(network)
NectoSDK.register(events)
```

- `URLSessionNetworkPlugin` 대신 `NectoNetworkPlugin`을 등록하는 앱은 아래 예제의
  `network.network` 자리에 그 플러그인을 넘기세요.
- 두 플러그인 중 등록되지 않은 것이 있으면 등록하세요. 각각 한 번씩만 등록해요.
  `install`에는 둘 다 필요해요. 브리지 메시지는 이벤트 플러그인으로, 요청은 네트워크
  플러그인으로 가요.

### 3. 캡처 설치하기

import를 추가하고, 같은 `#if DEBUG` 블록 안에서 `NectoSDK.start()`보다 먼저
호출하세요.

```swift
import NectoWebViewCapture

#if DEBUG
let network = URLSessionNetworkPlugin()
let events = NectoEventsPlugin()
NectoSDK.register(network)
NectoSDK.register(events)
NectoWebViewCapture.install(network: network.network, events: events)
NectoSDK.start()
#endif
```

`install`은 호출된 뒤에 설정된 것만 캡처해요. 그 뒤에 만들어진 WebView와 그 뒤에
등록된 메시지 핸들러예요. `WKWebView(`, `WKWebViewConfiguration(`,
`WKUserContentController`의 `.add(`를 검색하고 storyboard·nib 안의 WebView도 찾아서,
이 코드보다 먼저 실행되는 것이 없는지 확인하세요. 저장 프로퍼티와 싱글턴도 보세요.
`App` 타입이나 앱 delegate의 프로퍼티 초기값, 공유 WebView 풀은 `init` 안의 시작
코드보다 먼저 실행돼요. `App` 이니셜라이저나
`application(_:didFinishLaunchingWithOptions:)`의 시작 코드는 보통 가장 먼저 실행돼요.
더 일찍 WebView를 만들거나 핸들러를 등록하는 곳이 있으면 Necto 블록을 그보다 앞으로
옮기세요.

### 4. 앱의 브리지 방식 확인하기

앱의 네이티브 코드에서 아래 패턴을 각각 검색하고, 맞는 줄을 따르세요. 한 앱이 여러
방식을 같이 쓸 수도 있어요.

| 검색할 것 | 브리지 | 할 일 |
| --- | --- | --- |
| `WKScriptMessageHandler`, `WKUserContentController`의 `.add(` | 메시지 핸들러 | 없음. 자동으로 캡처돼요. |
| `WKScriptMessageHandlerWithReply`, `addScriptMessageHandler(` | 응답하는 메시지 핸들러 | 없음. 응답까지 자동으로 캡처돼요. |
| `evaluateJavaScript(`, `callAsyncJavaScript(` | 앱 → 페이지 호출 | 없음. 자동으로 캡처돼요. |
| 커스텀 scheme이나 host를 검사하는 `decidePolicyFor navigationAction` | URL scheme 브리지 | [URL scheme 브리지](#url-scheme-브리지)의 한 줄을 추가하세요. |
| `WebViewJavascriptBridge`, `WKWebViewJavascriptBridge` 같은 라이브러리 | 라이브러리 브리지 | [브리지 라이브러리](#브리지-라이브러리)를 보세요. |

서드파티 라이브러리의 소스는 고치지 마세요.

#### URL scheme 브리지

앱의 navigation delegate가 브리지 URL을 알아보는 곳에서, 처리하기 전에 보고하세요.

```swift
func webView(_ webView: WKWebView,
             decidePolicyFor navigationAction: WKNavigationAction,
             decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    if let url = navigationAction.request.url, url.scheme == "myapp" {
        #if DEBUG
        events.report(NectoEvent(
            level: .info,
            tag: "WebView",
            message: "web → app · \(url.host ?? url.absoluteString)",
            detail: ["url": url.absoluteString, "page": webView.url?.absoluteString ?? ""]
        ))
        #endif
        // 앱의 기존 처리는 여기서 그대로 이어져요.
    }
    // …
}
```

`events`는 2단계에서 등록한 인스턴스예요. delegate에서 닿지 않으면, 앱의 다른 디버그
전용 코드가 읽을 수 있는 곳에 참조를 두세요. 자동으로 캡처되는 줄과 함께 보이도록
`WebView` 태그와 `web → app · …` 형식을 쓰세요.

#### 브리지 라이브러리

라이브러리가 메시지를 어떻게 나르는지 확인하세요.

- 메시지 핸들러(`window.webkit.messageHandlers`)로 나르면 자동으로 캡처돼요.
- URL 가로채기로 나르면, 라이브러리가 보통 쌓인 메시지를 `evaluateJavaScript`로
  가져와요. 그래서 `result`에 메시지 묶음이 담긴 `app → web · evaluateJavaScript`
  이벤트로 보여요. 메시지를 한 줄씩 보고 싶으면, 앱이 라이브러리에 등록한 핸들러에서
  위와 같은 형식으로 보고하세요.

### 5. 빌드하기

Debug 구성으로 빌드하세요. Release도 빌드해서, 모든 Necto 호출이 `#if DEBUG` 안에
있는 채로 컴파일되는지 확인하세요. SDK의 다른 부분처럼 Release 빌드에도 모듈과
스크립트가 남을 수 있어요. `install`을 부르지 않으면 그 안의 어떤 것도 실행되지 않아요.

## 확인하기

Necto 앱을 켠 상태에서 시뮬레이터로 Debug 빌드를 실행하세요. WebView가 있는 화면을
열고, 페이지가 요청을 보내고 앱과 메시지를 주고받을 때까지 써 보세요.

Necto 앱에서:

- **Network**에 페이지의 요청이 `WebView` 배지와 함께 보여요.
- **Event Log**를 `WebView` 카테고리로 거르면 `web → app · …`, `app → web · …` 줄이
  보여요.

`necto`(`necto-cli`라는 이름으로도 설치돼요)로 확인할 수도 있어요. 먼저 기기와 앱을
찾으세요.

```bash
necto device list --json
```

그다음 기록을 읽어요. 하나 이상이 `"source": "WebView"`를 가지고 있어야 해요.

```bash
necto plugin send network-logger records.list --device <device-id> --app <bundle-id> --input '{"limit":100}'
```

이벤트도 읽어요. 하나 이상이 `"tag": "WebView"`를 가지고 있어야 해요.

```bash
necto plugin send event-log events.list --device <device-id> --app <bundle-id> --input '{"limit":100}'
```

## 끝난 기준

- [ ] `NectoWebViewCapture.install(network:events:)`이 `#if DEBUG` 안에서,
      `NectoSDK.start()`와 모든 `WKWebView` 생성보다 먼저 실행돼요.
- [ ] `install`에 넘긴 플러그인이 등록된 바로 그 인스턴스이고, 각각 한 번씩만
      등록돼요.
- [ ] 4단계에서 찾은 URL scheme 브리지가 모두 `WebView` 태그로 보고해요.
- [ ] 웹 코드는 바뀌지 않았어요.
- [ ] Debug와 Release가 모두 빌드돼요.
- [ ] Network에 WebView 기록이, Event Log에 `WebView` 이벤트가 보여요.

## 기록하는 내용

Network의 기록에는 `"source": "WebView"`가 붙어요. Event Log의 줄은 `WebView` 태그를
달고, detail에는 다음이 들어 있어요.

| 이벤트 | detail |
| --- | --- |
| `web → app · <name>` | `body`(JSON), `page`(프레임 URL), `frame`(`main` 또는 `sub`) |
| `app → web · <name> reply` | `reply`(JSON) 또는 `error`, `page` |
| `app → web · evaluateJavaScript` | `script`, `result`(JSON) 또는 `error`, `page`, `durationMs` |
| `app → web · callAsyncJavaScript` | `script`, `arguments`(JSON), `result`(JSON) 또는 `error`, `page`, `durationMs` |

- 앱이 페이지를 호출한 것은 끝났을 때 이벤트 하나로 보내고, 시각은 호출한 때로 적어요.
- 날짜처럼 JSON으로 담을 수 없는 값은 설명 문자열로 보여요. 값마다 64 KB에서 자르고
  전체 크기를 함께 적어요.
- 결과와 페이로드는 있는 그대로 기록해요. `document.cookie`를 읽는 스크립트라면
  Event Log에 쿠키가 보여요.
- `XMLHttpRequest`는 이미 디코딩된 본문을 넘겨주므로, 크기는 전송된 바이트가 아니라
  텍스트의 크기예요.

## 볼 수 없는 것

- 페이지 이동과 브라우저가 직접 불러오는 것: HTML 문서, 이미지, CSS, `<script>` 파일,
  폰트.
- Web Worker나 Service Worker 안에서 보낸 요청, 그리고 `fetch`나 `XMLHttpRequest`가
  아닌 통신: WebSocket, `EventSource`, `navigator.sendBeacon`.
- 스트리밍 응답의 본문. server-sent events, NDJSON 같은 스트림은 헤더가 도착할 때
  완료로 기록해요.
- 브라우저가 붙이는 헤더. `Cookie`, `User-Agent` 등이에요.
- CORS가 노출하지 않은 다른 origin 응답의 헤더.

이런 것은 Safari Web Inspector에서 모두 볼 수 있어요. Debug 빌드에서 WebView를 검사
가능하게 두고 Safari의 개발자용 메뉴에서 페이지를 여세요.

```swift
#if DEBUG
if #available(iOS 16.4, *) {
    webView.isInspectable = true
}
#endif
```

캡처가 켜져 있으면 페이지가 알아챌 수 있어요. `window.__nectoWebViewCapture`가
설정되고, `fetch.toString()`이 브라우저 원본과 달라요. 응답 본문을 읽다가 멈춘
페이지는 나머지가 다 도착해야 `cancel()`이 끝나요.

## 문제 해결

| 증상 | 가능한 원인 |
| --- | --- |
| 어떤 WebView에서도 아무것도 안 보여요 | WebView가 만들어진 뒤에 `install`이 실행됐거나, 실행 중인 빌드가 Debug가 아니에요. |
| 요청은 보이는데 브리지 메시지가 안 보여요 | 브리지가 URL scheme이나 라이브러리 방식이거나(4단계), 핸들러가 `install`보다 먼저 등록됐어요(3단계). |
| 캡처를 켜면 페이지 동작이 달라져요 | 페이지가 `fetch`가 브라우저 원본인지 검사하고 있어요. 그 실행에서는 `NectoWebViewCapture.uninstall()`을 부르고, 해당 페이지를 알려 주세요. |
| 요청 본문이 크기만 보여요 | 본문이 `FormData`, `Blob`, 바이너리 데이터였어요. 텍스트 본문만 기록돼요. |
| 요청 본문이 아예 없어요 | 본문이 스트림이었거나 `Request` 객체 안에 담겨 있었어요. 페이지의 업로드를 두 번 읽지 않도록 둘 다 읽지 않아요. |
| WebView를 설정한 뒤 캡처가 멈춰요 | 앱이 WebView를 만든 뒤 그 content controller에서 `removeAllUserScripts()`나 `removeAllScriptMessageHandlers()`를 불러, Necto의 스크립트와 receiver까지 지워졌어요. |

## 끄기

`NectoWebViewCapture.uninstall()`을 부르면 보고를 멈춰요. 이미 열린 페이지는 그대로
정상 동작해요.
