import UIKit
import WebKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = BrowserController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
    func applicationDidEnterBackground(_ application: UIApplication) {
        (window?.rootViewController as? BrowserController)?.saveSession()
    }
}

final class BrowserTab {
    let id = UUID()
    let web: WKWebView
    let isPrivate: Bool
    var home = true
    var epoch = 0
    var observations: [NSKeyValueObservation] = []
    var title: String { home ? (isPrivate ? "Private tab" : "New tab") : (web.title?.isEmpty == false ? web.title! : web.url?.host ?? "Loading…") }
    init(web: WKWebView, isPrivate: Bool) { self.web = web; self.isPrivate = isPrivate }
}

/// Native controls own every privileged action. Websites receive no message handlers or native bridge.
final class BrowserController: UIViewController, UITextFieldDelegate, WKNavigationDelegate, WKUIDelegate, UIAdaptivePresentationControllerDelegate {
    let store = BrowserStore()
    private var downloads: DownloadCoordinator?
    private var tabs: [BrowserTab] = []
    private var activeID: UUID?
    private var privateStore: WKWebsiteDataStore?
    private var privateProcessPool: WKProcessPool?
    private let normalProcessPool = WKProcessPool()
    private let address = UITextField()
    private let siteButton = UIButton(type: .system)
    private let tabButton = UIButton(type: .system)
    private let backButton = UIButton(type: .system)
    private let forwardButton = UIButton(type: .system)
    private let progress = UIProgressView(progressViewStyle: .bar)
    private let content = UIView()
    private let homeScroll = UIScrollView()
    private let homeStack = UIStackView()
    private let toolbar = UIStackView()
    private var fullscreenView: UIView?
    private var fullscreenExit: (() -> Void)?
    private var rules: WKContentRuleList?
    private var ruleGeneration = 0
    private var refreshControl: UIRefreshControl?
    private var clockTimer: Timer?
    private let clock = UILabel()
    private var current: BrowserTab? { tabs.first { $0.id == activeID } }
    private var preferences: BrowserPreferences { store.profile.preferences }
    private var pendingPermission: (() -> Void)?
    private var javascriptOff = Set<String>()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        buildChrome()
        applyAppearance()
        do { downloads = try DownloadCoordinator(store: store); downloads?.changed = { [weak self] in self?.tabButton.accessibilityHint = "Downloads can be reviewed in the menu" } }
        catch { showError(error) }
        NotificationCenter.default.addObserver(self, selector: #selector(backgrounded), name: UIApplication.didEnterBackgroundNotification, object: nil)
        compileRules { [weak self] in
            guard let self = self else { return }
            let restored = self.store.profile.session
            if restored.isEmpty { self.newTab() }
            else { for value in restored.prefix(20) { self.newTab(url: URL(string: value)) } }
            if self.tabs.isEmpty { self.newTab() }
            if let warning = self.store.warning { self.inform("Profile recovery", warning) }
        }
    }
    deinit { clockTimer?.invalidate(); NotificationCenter.default.removeObserver(self); downloads?.dispose() }
    override var prefersStatusBarHidden: Bool { fullscreenView != nil }
    @objc private func backgrounded() { saveSession() }

    private func icon(_ button: UIButton, _ symbol: String, _ label: String, action: Selector) {
        button.setImage(UIImage(systemName: symbol), for: .normal)
        button.accessibilityLabel = label
        button.addTarget(self, action: action, for: .touchUpInside)
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
    }
    private func buildChrome() {
        let top = UIStackView(); top.axis = .horizontal; top.spacing = 8; top.alignment = .center
        icon(siteButton, "slider.horizontal.3", "Site Control", action: #selector(siteControl))
        address.borderStyle = .roundedRect; address.placeholder = "Search or enter address"; address.keyboardType = .URL
        address.autocapitalizationType = .none; address.autocorrectionType = .no; address.returnKeyType = .go; address.clearButtonMode = .whileEditing
        address.accessibilityLabel = "Address and search"; address.delegate = self
        let reload = UIButton(type: .system); icon(reload, "arrow.clockwise", "Reload", action: #selector(reloadPage))
        top.addArrangedSubview(siteButton); top.addArrangedSubview(address); top.addArrangedSubview(reload)
        toolbar.axis = .horizontal; toolbar.distribution = .equalSpacing; toolbar.alignment = .center
        icon(backButton, "chevron.left", "Back", action: #selector(back))
        icon(forwardButton, "chevron.right", "Forward", action: #selector(forward))
        let home = UIButton(type: .system); icon(home, "house", "Home", action: #selector(homePage))
        icon(tabButton, "square.on.square", "Tabs", action: #selector(tabManager))
        let menu = UIButton(type: .system); icon(menu, "ellipsis.circle", "Menu", action: #selector(mainMenu))
        [backButton, forwardButton, home, tabButton, menu].forEach { toolbar.addArrangedSubview($0) }
        for element in [top, progress, content, toolbar] { element.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(element) }
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: safe.topAnchor), top.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 8), top.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -8), top.heightAnchor.constraint(equalToConstant: 52),
            progress.topAnchor.constraint(equalTo: top.bottomAnchor), progress.leadingAnchor.constraint(equalTo: view.leadingAnchor), progress.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.bottomAnchor.constraint(equalTo: safe.bottomAnchor), toolbar.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 14), toolbar.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -14), toolbar.heightAnchor.constraint(equalToConstant: 50),
            content.topAnchor.constraint(equalTo: progress.bottomAnchor), content.bottomAnchor.constraint(equalTo: toolbar.topAnchor), content.leadingAnchor.constraint(equalTo: safe.leadingAnchor), content.trailingAnchor.constraint(equalTo: safe.trailingAnchor)
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        homeScroll.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(homeScroll)
        NSLayoutConstraint.activate([homeScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor), homeScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor), homeScroll.topAnchor.constraint(equalTo: content.topAnchor), homeScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        homeStack.axis = .vertical; homeStack.spacing = 18; homeStack.translatesAutoresizingMaskIntoConstraints = false; homeScroll.addSubview(homeStack)
        NSLayoutConstraint.activate([homeStack.leadingAnchor.constraint(equalTo: homeScroll.contentLayoutGuide.leadingAnchor, constant: 24), homeStack.trailingAnchor.constraint(equalTo: homeScroll.contentLayoutGuide.trailingAnchor, constant: -24), homeStack.topAnchor.constraint(equalTo: homeScroll.contentLayoutGuide.topAnchor, constant: 28), homeStack.bottomAnchor.constraint(equalTo: homeScroll.contentLayoutGuide.bottomAnchor, constant: -28), homeStack.widthAnchor.constraint(equalTo: homeScroll.frameLayoutGuide.widthAnchor, constant: -48)])
    }
    @objc private func keyboardChanged(_ note: Notification) {
        guard let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let local = view.convert(end, from: nil)
        let overlap = max(0, view.bounds.maxY - local.minY - view.safeAreaInsets.bottom)
        current?.web.scrollView.contentInset.bottom = overlap
        current?.web.scrollView.verticalScrollIndicatorInsets.bottom = overlap
    }
    private func applyAppearance() {
        overrideUserInterfaceStyle = preferences.appearance == "dark" ? .dark : preferences.appearance == "light" ? .light : .unspecified
        let colors: [String: UIColor] = ["violet": .systemPurple, "mint": .systemTeal, "blue": .systemBlue]
        view.tintColor = colors[preferences.accent] ?? .systemPurple
    }
    private func compileRules(completion: @escaping () -> Void) {
        ruleGeneration += 1; let generation = ruleGeneration
        do {
            let encoded = try MobileShield.contentRules(preferences)
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "aster-mobile-shield", encodedContentRuleList: encoded) { [weak self] list, error in
                DispatchQueue.main.async {
                    guard let self = self, generation == self.ruleGeneration else { return }
                    if let error = error { self.showError(error); completion(); return }
                    self.rules = list
                    for tab in self.tabs { tab.web.configuration.userContentController.removeAllContentRuleLists(); if let list = list { tab.web.configuration.userContentController.add(list) } }
                    completion()
                }
            }
        } catch { showError(error); completion() }
    }
    func newTab(url: URL? = nil, privateMode: Bool = false) {
        guard tabs.count < 20 else { inform("Tab limit", "Close a tab before opening another. Maximum: 20."); return }
        let configuration = WKWebViewConfiguration()
        if privateMode {
            if privateStore == nil { privateStore = .nonPersistent(); privateProcessPool = WKProcessPool() }
            configuration.websiteDataStore = privateStore!; configuration.processPool = privateProcessPool!
        } else { configuration.websiteDataStore = .default(); configuration.processPool = normalProcessPool }
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.userContentController = WKUserContentController()
        if let rules = rules { configuration.userContentController.add(rules) }
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.allowsBackForwardNavigationGestures = true; web.navigationDelegate = self; web.uiDelegate = self
        let tab = BrowserTab(web: web, isPrivate: privateMode)
        tab.observations = [web.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in self?.refreshChrome() }, web.observe(\.title, options: [.new]) { [weak self] _, _ in self?.refreshChrome() }, web.observe(\.isLoading, options: [.new]) { [weak self] _, _ in self?.refreshChrome() }]
        let refresh = UIRefreshControl(); refresh.addTarget(self, action: #selector(reloadPage), for: .valueChanged); web.scrollView.refreshControl = refresh
        tabs.append(tab); select(tab.id)
        if let url = url { navigate(url, tab: tab) }
        saveSession()
    }
    private func select(_ id: UUID) {
        pendingPermission?(); pendingPermission = nil
        current?.web.removeFromSuperview(); activeID = id
        guard let tab = current else { return }
        tab.web.translatesAutoresizingMaskIntoConstraints = false; content.insertSubview(tab.web, belowSubview: homeScroll)
        NSLayoutConstraint.activate([tab.web.leadingAnchor.constraint(equalTo: content.leadingAnchor), tab.web.trailingAnchor.constraint(equalTo: content.trailingAnchor), tab.web.topAnchor.constraint(equalTo: content.topAnchor), tab.web.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        renderHome(); refreshChrome()
        if !UIAccessibility.isReduceMotionEnabled { tab.web.alpha = 0.8; UIView.animate(withDuration: 0.16) { tab.web.alpha = 1 } }
    }
    private func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        pendingPermission?(); pendingPermission = nil
        let tab = tabs.remove(at: index); tab.web.stopLoading(); tab.web.navigationDelegate = nil; tab.web.uiDelegate = nil; tab.observations.removeAll(); tab.web.removeFromSuperview()
        if !tabs.contains(where: { $0.isPrivate }) { privateStore = nil; privateProcessPool = nil }
        if tabs.isEmpty { activeID = nil; newTab() }
        else if id == activeID { select(tabs[min(index, tabs.count - 1)].id) }
        saveSession(); refreshChrome()
    }
    func saveSession() {
        do { try store.update { $0.session = tabs.filter { !$0.isPrivate && !$0.home }.compactMap { $0.web.url }.filter { (try? WebPolicy.webURL($0.absoluteString)) != nil }.map(\.absoluteString) } }
        catch { showError(error) }
    }
    private func refreshChrome() {
        guard isViewLoaded else { return }
        let tab = current
        if !address.isFirstResponder { address.text = tab?.home == true ? "" : tab?.web.url?.absoluteString }
        backButton.isEnabled = tab?.web.canGoBack == true; forwardButton.isEnabled = tab?.web.canGoForward == true
        tabButton.accessibilityValue = "\(tabs.count) tabs"; tabButton.setTitle(" \(tabs.count)", for: .normal)
        progress.progress = Float(tab?.web.estimatedProgress ?? 0); progress.isHidden = tab?.web.isLoading != true
        siteButton.setImage(UIImage(systemName: tab?.isPrivate == true ? "hand.raised" : tab?.web.hasOnlySecureContent == true && tab?.web.url?.scheme == "https" ? "lock" : "slider.horizontal.3"), for: .normal)
        if tab?.web.isLoading == false { tab?.web.scrollView.refreshControl?.endRefreshing() }
    }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        do { let url = try WebPolicy.resolve(textField.text ?? "", engine: preferences.searchEngine); textField.resignFirstResponder(); if let tab = current { navigate(url, tab: tab) } }
        catch { showError(error) }
        return true
    }
    private func navigate(_ url: URL, tab: BrowserTab) {
        do { _ = try WebPolicy.webURL(url.absoluteString); tab.home = false; renderHome(); tab.web.load(URLRequest(url: url)) }
        catch { showError(error) }
    }
    @objc private func back() { current?.web.goBack() }
    @objc private func forward() { current?.web.goForward() }
    @objc private func reloadPage() { guard let tab = current else { return }; if tab.home { renderHome() } else { tab.web.reload() } }
    @objc private func homePage() {
        guard let tab = current else { return }
        if let url = try? WebPolicy.webURL(preferences.homepage) { navigate(url, tab: tab); return }
        tab.epoch += 1; pendingPermission?(); pendingPermission = nil; tab.web.stopLoading(); tab.home = true
        // Retire scripts from the previous page rather than hiding an active document.
        tab.web.loadHTMLString("<!doctype html><title></title>", baseURL: nil)
        renderHome(); saveSession()
    }
    private func renderHome() {
        guard let tab = current else { return }
        homeScroll.isHidden = !tab.home; tab.web.isHidden = tab.home
        guard tab.home else { return }
        homeStack.arrangedSubviews.forEach { homeStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        let brand = UILabel(); brand.text = "✦ aster"; brand.font = .systemFont(ofSize: 36, weight: .semibold); brand.textColor = view.tintColor; homeStack.addArrangedSubview(brand)
        clock.font = .preferredFont(forTextStyle: .title2); clock.adjustsFontForContentSizeCategory = true; clock.text = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short); homeStack.addArrangedSubview(clock)
        let description = UILabel(); description.numberOfLines = 0; description.font = .preferredFont(forTextStyle: .body)
        description.text = tab.isPrivate ? "Private browsing uses memory-only website storage. It is not network anonymity. Bookmarks and explicitly downloaded files remain. Private tabs and history are not restored." : "A little space. Endless possibilities. Search or enter a website above."
        homeStack.addArrangedSubview(description)
        homeStack.addArrangedSubview(actionButton("Search the web", symbol: "magnifyingglass") { [weak self] in self?.address.becomeFirstResponder() })
        homeStack.addArrangedSubview(actionButton("New private tab", symbol: "hand.raised") { [weak self] in self?.newTab(privateMode: true) })
        let items = Array(store.profile.bookmarks.prefix(6))
        for item in items { homeStack.addArrangedSubview(actionButton(item.title, symbol: "star") { [weak self] in if let url = URL(string: item.url), let current = self?.current { self?.navigate(url, tab: current) } }) }
        if !tab.isPrivate {
            let visited = Dictionary(grouping: store.profile.history, by: { URL(string: $0.url)?.host ?? "" }).filter { !$0.key.isEmpty }.sorted { $0.value.count > $1.value.count }.prefix(4)
            for (host, visits) in visited { homeStack.addArrangedSubview(actionButton(host, symbol: "clock") { [weak self] in if let value = visits.first?.url, let url = URL(string: value), let current = self?.current { self?.navigate(url, tab: current) } }) }
        }
        clockTimer?.invalidate(); clockTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.clock.text = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short) }
    }
    private func actionButton(_ title: String, symbol: String, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.tinted(); configuration.title = title; configuration.image = UIImage(systemName: symbol); configuration.imagePadding = 10; configuration.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() }); button.titleLabel?.numberOfLines = 2; button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true; return button
    }

    // MARK: Navigation and permissions
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let tab = tabs.first(where: { $0.web === webView }), let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if url.absoluteString == "about:blank" && tab.home { decisionHandler(.allow); return }
        guard (try? WebPolicy.webURL(url.absoluteString)) != nil else { decisionHandler(.cancel); if tab.id == activeID { inform("Navigation blocked", "Aster opens HTTP/HTTPS websites only. Local files, custom application schemes and unsafe URLs are not launched.") }; return }
        if let category = MobileShield.blocked(url, preferences: preferences) {
            decisionHandler(.cancel)
            if navigationAction.targetFrame?.isMainFrame != false && tab.id == activeID { inform(category == .adult ? "ASTER CONTENT PROTECTION" : "ASTER SECURITY WARNING", "Blocked by \(category.rawValue): \(url.host ?? "website"). Review your domain lists/exceptions in Mobile Shield. Classification may be incomplete or incorrect.") }
            return
        }
        if navigationAction.shouldPerformDownload {
            decisionHandler(.cancel); confirmDownload(url: url, name: url.lastPathComponent, mime: "Unknown", size: -1, tab: tab, method: navigationAction.request.httpMethod ?? "GET"); return
        }
        if navigationAction.targetFrame == nil {
            decisionHandler(.cancel)
            if tab.id == activeID && navigationAction.navigationType == .linkActivated { confirm("Open new tab?", "This website wants to open \(url.host ?? "a page").") { [weak self, weak tab] in guard let self = self, let tab = tab, self.activeID == tab.id else { return }; self.newTab(url: url, privateMode: tab.isPrivate) } }
            return
        }
        if navigationAction.targetFrame?.isMainFrame == true { tab.home = false; renderHome() }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences pagePreferences: WKWebpagePreferences, decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        pagePreferences.allowsContentJavaScript = !javascriptOff.contains(WebPolicy.origin(navigationAction.request.url) ?? "")
        self.webView(webView, decidePolicyFor: navigationAction) { decisionHandler($0, pagePreferences) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard let url = navigationResponse.response.url, let tab = tabs.first(where: { $0.web === webView }) else { decisionHandler(.cancel); return }
        if url.absoluteString == "about:blank" && tab.home { decisionHandler(.allow); return }
        guard (try? WebPolicy.webURL(url.absoluteString)) != nil, MobileShield.blocked(url, preferences: preferences) == nil else { decisionHandler(.cancel); return }
        let disposition = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        if !navigationResponse.canShowMIMEType || disposition.contains("attachment") {
            decisionHandler(.cancel)
            if navigationResponse.isForMainFrame { confirmDownload(url: url, name: navigationResponse.response.suggestedFilename ?? url.lastPathComponent, mime: navigationResponse.response.mimeType ?? "Unknown", size: navigationResponse.response.expectedContentLength, tab: tab, method: "GET") }
            return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if let tab = tabs.first(where: { $0.web === webView }) { tab.epoch += 1 }
        pendingPermission?(); pendingPermission = nil
        refreshChrome()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let tab = tabs.first(where: { $0.web === webView }) else { return }
        if !tab.home, !tab.isPrivate, let url = webView.url { do { try store.visit(url, title: webView.title ?? url.host ?? url.absoluteString) } catch { showError(error) } }
        saveSession(); refreshChrome()
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { pageError(webView, error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { pageError(webView, error) }
    private func pageError(_ webView: WKWebView, _ error: Error) { refreshChrome(); if webView === current?.web && (error as NSError).code != NSURLErrorCancelled { inform("Page could not load", error.localizedDescription) } }
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) { completionHandler(.performDefaultHandling, nil) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { if webView === current?.web { inform("Page process stopped", "Reload the page to recover. Other tabs remain available.") } }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        guard let tab = tabs.first(where: { $0.web === webView }), tab.id == activeID, !tab.home, frame.isMainFrame, origin.protocol == "https", origin.host.lowercased() == webView.url?.host?.lowercased(), origin.port == (webView.url?.port ?? 0) || origin.port == 443 && webView.url?.port == nil, presentedViewController == nil else { decisionHandler(.deny); return }
        let captured = tab.epoch, site = WebPolicy.origin(webView.url)
        var completed = false
        let finish: (WKPermissionDecision) -> Void = { result in if !completed { completed = true; decisionHandler(result) } }
        pendingPermission = { finish(.deny) }
        let kind = type == .camera ? "camera" : type == .microphone ? "microphone" : "camera and microphone"
        let alert = UIAlertController(title: "ASTER SITE CONTROL", message: "\(site ?? origin.host) requests \(kind). iOS may request its own system authorization. This grant lasts only as managed by WebKit; Aster stores no global permission rule.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Block", style: .cancel) { [weak self] _ in finish(.deny); self?.pendingPermission = nil })
        alert.addAction(UIAlertAction(title: "Allow this request", style: .default) { [weak self, weak tab] _ in
            guard let self = self, let tab = tab, self.activeID == tab.id, tab.epoch == captured, WebPolicy.origin(tab.web.url) == site else { finish(.deny); return }
            finish(.grant); self.pendingPermission = nil
        })
        present(alert, animated: !UIAccessibility.isReduceMotionEnabled)
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard webView === current?.web, presentedViewController == nil else { completionHandler(); return }
        let alert = UIAlertController(title: webView.url?.host ?? "Website", message: String(message.prefix(1500)), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() }); present(alert, animated: true)
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard webView === current?.web, presentedViewController == nil else { completionHandler(false); return }
        let alert = UIAlertController(title: webView.url?.host ?? "Website", message: String(message.prefix(1500)), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) }); alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) }); present(alert, animated: true)
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        guard webView === current?.web, presentedViewController == nil else { completionHandler(nil); return }
        let alert = UIAlertController(title: webView.url?.host ?? "Website", message: String(prompt.prefix(1500)), preferredStyle: .alert); alert.addTextField { $0.text = String((defaultText ?? "").prefix(1000)) }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) }); alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(alert.textFields?.first?.text) }); present(alert, animated: true)
    }

    // MARK: Download Guard
    private func confirmDownload(url: URL, name: String, mime: String, size: Int64, tab: BrowserTab, method: String) {
        guard tab.id == activeID, tabs.contains(where: { $0 === tab }), presentedViewController == nil else { return }
        guard method == "GET", url.scheme == "https", size <= DownloadInspector.maximumBytes else { inform("Download unavailable", "This preview supports confirmed HTTPS GET downloads up to 100 MiB. POST, HTTP, blob/data, and redirected downloads are not supported."); return }
        let epoch = tab.epoch, cleaned = WebPolicy.filename(name.isEmpty ? "download" : name)
        let message = "File: \(cleaned)\nType: \(mime)\nSize: \(size >= 0 ? ByteCountFormatter.string(fromByteCount: size, countStyle: .file) : "Unknown")\nSource: \(url.host ?? "Unknown")\nHTTPS: yes\nSecurity: UNVERIFIED — no antivirus service configured.\n\nLocal hash/type checks do not establish safety. No file is uploaded to a scanner. Redirects are refused.\(tab.isPrivate ? "\nPrivate download files remain until you delete them; their records are not saved across launches." : "")"
        confirm("ASTER DOWNLOAD GUARD", message, proceed: "Download & check locally") { [weak self, weak tab] in
            guard let self = self, let tab = tab, self.activeID == tab.id, tab.epoch == epoch else { return }
            tab.web.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self, weak tab] cookies in
                DispatchQueue.main.async {
                    guard let self = self, let tab = tab, self.activeID == tab.id, tab.epoch == epoch else { return }
                    let selected = DownloadCoordinator.cookiesFor(url: url, cookies: cookies)
                    do { guard let downloads = self.downloads else { throw BrowserFailure(message: "Download storage is unavailable.") }; try downloads.start(url: url, name: cleaned, mime: mime, size: size, cookies: selected, privateMode: tab.isPrivate); self.inform("Download started", "Review progress, risk checks and file export in Downloads. Files never open automatically.") }
                    catch { self.showError(error) }
                }
            }
        }
    }

    // MARK: Native sheets and menus
    private func sheet(_ title: String, message: String? = nil, choices: [(String, () -> Void)]) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .actionSheet)
        for (label, action) in choices { alert.addAction(UIAlertAction(title: label, style: .default) { _ in action() }) }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.popoverPresentationController?.sourceView = toolbar; alert.popoverPresentationController?.sourceRect = toolbar.bounds
        present(alert, animated: !UIAccessibility.isReduceMotionEnabled)
    }
    func inform(_ title: String, _ message: String) {
        guard isViewLoaded, view.window != nil, presentedViewController == nil else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert); alert.addAction(UIAlertAction(title: "OK", style: .default)); present(alert, animated: !UIAccessibility.isReduceMotionEnabled)
    }
    private func confirm(_ title: String, _ message: String, proceed: String = "Continue", action: @escaping () -> Void) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel)); alert.addAction(UIAlertAction(title: proceed, style: .default) { _ in action() }); present(alert, animated: !UIAccessibility.isReduceMotionEnabled)
    }
    private func showError(_ error: Error) { inform("Aster", error.localizedDescription) }
    private func edit(_ title: String, fields: [(String, String)], action: @escaping ([String]) throws -> Void) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        for (placeholder, text) in fields { alert.addTextField { $0.placeholder = placeholder; $0.text = text; $0.autocapitalizationType = .none; $0.autocorrectionType = .no } }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel)); alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self] _ in do { try action(alert.textFields?.map { $0.text ?? "" } ?? []) } catch { self?.showError(error) } }); present(alert, animated: true)
    }
    @objc private func tabManager() {
        let rows = tabs.map { tab in NativeRow(id: tab.id, title: tab.title, subtitle: tab.isPrivate ? "Private · not restored" : tab.home ? "Start page" : tab.web.url?.absoluteString ?? "Loading", action: { [weak self] in self?.select(tab.id) }, delete: { [weak self] in self?.closeTab(tab.id) }) }
        showList("Tabs (\(tabs.count)/20)", rows: rows, add: { [weak self] in self?.newTab() })
    }
    private func showList(_ title: String, rows: [NativeRow], add: (() -> Void)? = nil) {
        let list = NativeListController(title: title, rows: rows, add: add)
        let navigation = UINavigationController(rootViewController: list)
        present(navigation, animated: !UIAccessibility.isReduceMotionEnabled)
    }
    @objc private func mainMenu() {
        sheet("Aster", choices: [
            ("New tab", { [weak self] in self?.newTab() }), ("New private tab", { [weak self] in self?.newTab(privateMode: true) }),
            ("Bookmark this page", { [weak self] in self?.bookmarkCurrent() }), ("Bookmarks", { [weak self] in self?.bookmarks() }),
            ("History", { [weak self] in self?.history() }), ("Downloads", { [weak self] in self?.downloadList() }),
            ("Mobile Shield", { [weak self] in self?.shieldSettings() }), ("Settings", { [weak self] in self?.settings() }),
            ("Share website link", { [weak self] in if let url = self?.current?.web.url, (try? WebPolicy.webURL(url.absoluteString)) != nil { self?.share([url]) } })
        ])
    }
    private func bookmarkCurrent() {
        guard let tab = current, !tab.home, let url = tab.web.url else { return }
        edit("Save bookmark", fields: [("Title", tab.title), ("Folder", "")]) { [weak self] values in try self?.store.bookmark(url, title: values[0], folder: values[1]) }
    }
    private func bookmarks() {
        showList("Bookmarks", rows: store.profile.bookmarks.map { item in NativeRow(id: item.id, title: item.title, subtitle: (item.folder.isEmpty ? "" : item.folder + " · ") + item.url, action: { [weak self] in
            self?.sheet(item.title, choices: [("Open", { [weak self] in if let url = URL(string: item.url), let tab = self?.current { self?.navigate(url, tab: tab) } }), ("Edit title/folder", { [weak self] in self?.edit("Edit bookmark", fields: [("Title", item.title), ("Folder", item.folder)]) { [weak self] values in if let url = URL(string: item.url) { try self?.store.bookmark(url, title: values[0], folder: values[1]) } } })])
        }, delete: { [weak self] in do { try self?.store.update { $0.bookmarks.removeAll { $0.id == item.id } } } catch { self?.showError(error) } }) })
    }
    private func history() {
        showList("History", rows: store.profile.history.map { item in NativeRow(id: item.id, title: item.title, subtitle: DateFormatter.localizedString(from: item.date, dateStyle: .short, timeStyle: .short) + " · " + item.url, action: { [weak self] in if let url = URL(string: item.url), let tab = self?.current { self?.navigate(url, tab: tab) } }, delete: { [weak self] in do { try self?.store.update { $0.history.removeAll { $0.id == item.id } } } catch { self?.showError(error) } }) })
    }
    private func downloadList() {
        guard let downloads = downloads else { inform("Downloads unavailable", "App-local download storage could not be prepared."); return }
        let records = downloads.records.filter { !$0.isPrivate || current?.isPrivate == true }
        showList("Download Guard", rows: records.map { record in NativeRow(id: record.id, title: record.name, subtitle: "\(record.state) · \(ByteCountFormatter.string(fromByteCount: record.received, countStyle: .file)) · \(record.scan?.verdict ?? "UNVERIFIED")", action: { [weak self] in self?.downloadDetail(record.id) }, delete: { [weak self] in do { try self?.downloads?.remove(record.id) } catch { self?.showError(error) } }) })
    }
    private func downloadDetail(_ id: UUID) {
        guard let downloads = downloads, let r = downloads.records.first(where: { $0.id == id }) else { return }
        let report = "\(r.name)\n\(r.source)\n\(r.mime)\n\(r.state) · \(r.scan?.verdict ?? "UNVERIFIED")\nSHA-256: \(r.scan?.sha256 ?? "Not calculated")\n\(r.scan?.reasons.joined(separator: "\n") ?? "No antivirus scan available.")\n\(r.error ?? "")"
        var choices: [(String, () -> Void)] = [("View report", { [weak self] in self?.inform("Download report", report) }), ("Export report", { [weak self] in do { self?.share([try downloads.reportURL(id)]) } catch { self?.showError(error) } })]
        if r.state == "Downloading" { choices.append(("Cancel download", { downloads.cancel(id) })) }
        if r.state == "Completed" {
            choices.append(("Repeat local checks", { [weak self] in do { try downloads.inspectAgain(id) } catch { self?.showError(error) } }))
            choices.append(("Export file…", { [weak self] in self?.confirm("Export unverified file?", "\(r.scan?.verdict ?? "UNVERIFIED"). No antivirus service scanned this file. Exporting may offer other apps access. Never install untrusted files.", proceed: "Choose export destination") { [weak self] in self?.share([downloads.fileURL(r)]) } }))
        }
        sheet("ASTER DOWNLOAD GUARD", message: "Files never open automatically. Refresh Downloads to see current progress.", choices: choices)
    }
    private func share(_ items: [Any]) { let controller = UIActivityViewController(activityItems: items, applicationActivities: nil); controller.popoverPresentationController?.sourceView = toolbar; controller.popoverPresentationController?.sourceRect = toolbar.bounds; present(controller, animated: true) }
    @objc private func siteControl() {
        guard let tab = current, !tab.home, let site = WebPolicy.origin(tab.web.url) else { inform("Site Control", "Open a website first."); return }
        let siteURL = tab.web.url!, epoch = tab.epoch
        tab.web.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self, weak tab] cookies in DispatchQueue.main.async {
            guard let self = self, let tab = tab, self.activeID == tab.id, tab.epoch == epoch, WebPolicy.origin(tab.web.url) == site else { return }
            let selected = DownloadCoordinator.cookiesFor(url: siteURL, cookies: cookies)
            self.sheet("ASTER SITE CONTROL", message: "\(site)\n\(tab.web.hasOnlySecureContent && siteURL.scheme == "https" ? "HTTPS encryption reported; not a safety guarantee." : "Connection is not verified as fully HTTPS.")\nCookies for this URL: \(selected.count) (values hidden)\n\(tab.isPrivate ? "Memory-only private website store." : "Persistent website store.")\nCamera/microphone require site and iOS permission. Other unsupported permissions are not exposed as switches.", choices: [
                (self.javascriptOff.contains(site) ? "Allow JavaScript (reload)" : "Block JavaScript (reload)", { [weak self, weak tab] in guard let self = self, let tab = tab, self.activeID == tab.id, tab.epoch == epoch else { return }; if self.javascriptOff.contains(site) { self.javascriptOff.remove(site) } else { self.javascriptOff.insert(site) }; tab.web.reload() }),
                ("Clear this website’s data", { [weak self, weak tab] in self?.confirm("Clear website data?", "You may be signed out. WebKit website records are grouped by domain; this may affect sibling sites. Bookmarks/files remain.") { [weak self, weak tab] in guard let self = self, let tab = tab, self.activeID == tab.id, tab.epoch == epoch else { return }; self.clearSite(tab, url: siteURL) } }),
                ("Mobile Shield", { [weak self] in self?.shieldSettings() })
            ])
        }}
    }
    private func clearSite(_ tab: BrowserTab, url: URL) {
        let data = tab.web.configuration.websiteDataStore
        data.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            let host = url.host?.lowercased() ?? ""
            let selected = records.filter { !$0.displayName.isEmpty && (host == $0.displayName.lowercased() || host.hasSuffix("." + $0.displayName.lowercased())) }
            data.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: selected) { [weak self] in self?.inform("Website data cleared", "Matching WebKit domain records were removed. Reload the website.") }
        }
    }
    private func settings() {
        sheet("Settings", message: "This preview has no sync, password manager, VPN service, alternate engine, signed in-app updater or third-party malware scanner. Unsupported options are not shown as working switches.", choices: [
            ("Appearance", { [weak self] in self?.sheet("Appearance", choices: ["system", "light", "dark"].map { mode in (mode.capitalized, { [weak self] in do { try self?.store.update { $0.preferences.appearance = mode }; self?.applyAppearance() } catch { self?.showError(error) } }) }) }),
            ("Accent color", { [weak self] in self?.sheet("Accent color", choices: ["violet", "mint", "blue"].map { color in (color.capitalized, { [weak self] in do { try self?.store.update { $0.preferences.accent = color }; self?.applyAppearance(); self?.renderHome() } catch { self?.showError(error) } }) }) }),
            ("Search engine", { [weak self] in self?.sheet("Search engine", choices: ["google", "bing", "duckduckgo"].map { engine in (engine, { [weak self] in do { try self?.store.update { $0.preferences.searchEngine = engine } } catch { self?.showError(error) } }) }) }),
            ("Homepage", { [weak self] in self?.edit("Homepage (empty = Aster start page)", fields: [("https://…", self?.preferences.homepage ?? "")]) { [weak self] values in let raw = values[0].trimmingCharacters(in: .whitespacesAndNewlines); if !raw.isEmpty { _ = try WebPolicy.webURL(raw) }; try self?.store.update { $0.preferences.homepage = raw } } }),
            ("Clear normal browsing data", { [weak self] in self?.confirm("Clear normal data?", "Deletes normal website cookies/storage/cache and Aster history/session URLs. Private store, bookmarks and files are retained.") { [weak self] in WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { [weak self] in do { try self?.store.update { $0.history = []; $0.session = [] }; self?.inform("Cleared", "Normal website data and history were removed.") } catch { self?.showError(error) } } } }),
            ("About privacy", { [weak self] in self?.inform("Aster Mobile 4.0 preview", "No account sync or analytics backend. Website traffic goes to the sites you visit and your chosen search provider. Local downloads are not antivirus-scanned or uploaded. WebKit fraudulent-site warnings may use Apple’s configured safe-browsing services. Domain lists are user supplied and may be inaccurate. iOS manages DNS/network permissions. This is not a production-security certification.") })
        ])
    }
    private func shieldSettings() {
        let p = preferences
        sheet("ASTER MOBILE SHIELD", message: "Mode: \(p.shieldMode). User-supplied entries — threats: \(p.threatDomains.count), trackers: \(p.trackerDomains.count), content: \(p.adultDomains.count).\nNo bundled threat/classification feed or scanning API is configured. Empty lists do not provide list-based protection. WebKit fraudulent-site warnings remain enabled. Domain filtering is imperfect; it does not classify page content.", choices: [
            ("Protection mode", { [weak self] in self?.sheet("Protection mode", message: "Standard: threat list. Enhanced: threats + trackers. Strict: all lists including optional content domains.", choices: MobileShield.modes.map { mode in (mode.capitalized, { [weak self] in self?.updateShield { $0.shieldMode = mode } }) }) }),
            ("Threat domains", { [weak self] in self?.editDomains("Threat domains", kind: "threat") }),
            ("Tracker domains", { [weak self] in self?.editDomains("Tracker domains", kind: "tracker") }),
            ("Adult/content domains", { [weak self] in self?.editDomains("Adult/content domains", kind: "adult") }),
            ("Allowed exceptions", { [weak self] in self?.editDomains("Allowed domain exceptions", kind: "exception") })
        ])
    }
    private func updateShield(_ change: @escaping (inout BrowserPreferences) -> Void) {
        var next = preferences; change(&next)
        do { _ = try MobileShield.contentRules(next) } catch { showError(error); return }
        let previous = preferences
        do { try store.update { $0.preferences = next } } catch { showError(error); return }
        compileRules { [weak self] in
            guard let self = self else { return }
            if self.rules == nil { try? self.store.update { $0.preferences = previous }; return }
            self.inform("Shield rules updated", "Reload existing websites to apply the new list. Classification is not perfect; no protection is claimed for domains not in your lists.")
        }
    }
    private func editDomains(_ title: String, kind: String) {
        let p = preferences
        let initial = kind == "threat" ? p.threatDomains : kind == "tracker" ? p.trackerDomains : kind == "adult" ? p.adultDomains : p.exceptions
        let editor = DomainEditorController(title: title, initial: initial.joined(separator: "\n")) { [weak self] raw in
            let values = try MobileShield.parse(raw)
            self?.updateShield { prefs in if kind == "threat" { prefs.threatDomains = values } else if kind == "tracker" { prefs.trackerDomains = values } else if kind == "adult" { prefs.adultDomains = values } else { prefs.exceptions = values } }
        }
        present(UINavigationController(rootViewController: editor), animated: true)
    }
}
