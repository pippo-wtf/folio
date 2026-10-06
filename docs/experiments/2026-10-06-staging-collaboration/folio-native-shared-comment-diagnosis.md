# Installed shared-comment no-op — bounded diagnosis

Parent observed installed Staging Shared comment popover activation hide the popover without annotation/composer. Diagnosis-only native test added: `CollaborationReviewTests.testActualNativeBridgeSharedCommentAfterCheckboxCreatesComposer`.

This test uses actual ReaderWebView.Coordinator main-frame WKScriptMessage routing through the renderer harness (not the simplified CopyContentTests bridge). It loads a freshly registered disposable document, enables shared mode/source saving, clicks the actual Markdown checkbox and waits for guarded source update, selects the heading's rendered text, checks Folio.sharedSelection with current model token, focuses/activates the actual web Shared comment button, and asserts one emitted intent, one durable shared annotation, selected composer thread, Shared mode, nil issue and clean reader draft.

- Original activation: GREEN 1/1, 1.336 seconds, `/private/tmp/folio-native-shared-comment-repro.log`.
- Explicit browser button focus before activation: GREEN 1/1, 1.502 seconds, `/private/tmp/folio-native-shared-comment-focus-repro.log`.

No product code changed. The current source's basic bridge/token/mode/selection path works in these native WKWebView tests. The installed no-op remains unproven here: this harness uses programmatic DOM selection/activation and does not host the full native window or reproduce physical mouse/AX selection timing. Root owns installed UI observation; possible next distinctions are full native hosting/focus, live installed mode/token/state, selected region/deferred complex editor, and installed executable/resource freshness. These are investigation candidates, not established causes.
