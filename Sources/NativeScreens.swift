import UIKit

struct NativeRow {
    let id: UUID
    let title: String
    let subtitle: String
    let action: () -> Void
    let delete: (() -> Void)?
}

final class NativeListController: UITableViewController, UISearchResultsUpdating {
    private var rows: [NativeRow]
    private var filtered: [NativeRow] = []
    private let addAction: (() -> Void)?
    private let search = UISearchController(searchResultsController: nil)
    init(title: String, rows: [NativeRow], add: (() -> Void)? = nil) {
        self.rows = rows; self.filtered = rows; self.addAction = add
        super.init(style: .insetGrouped); self.title = title
    }
    required init?(coder: NSCoder) { fatalError("Storyboard construction is unsupported") }
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(done))
        if addAction != nil { navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(add)) }
        search.searchResultsUpdater = self; search.obscuresBackgroundDuringPresentation = false
        navigationItem.searchController = search; definesPresentationContext = true
        tableView.rowHeight = UITableView.automaticDimension; tableView.estimatedRowHeight = 78
    }
    @objc private func done() { dismiss(animated: true) }
    @objc private func add() { let action = addAction; dismiss(animated: !UIAccessibility.isReduceMotionEnabled) { action?() } }
    func updateSearchResults(for searchController: UISearchController) {
        let query = searchController.searchBar.text ?? ""
        filtered = query.isEmpty ? rows : rows.filter { ($0.title + " " + $0.subtitle).localizedCaseInsensitiveContains(query) }
        tableView.reloadData()
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { filtered.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = filtered[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "row") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "row")
        cell.textLabel?.text = row.title; cell.textLabel?.numberOfLines = 2; cell.textLabel?.font = .preferredFont(forTextStyle: .body)
        cell.detailTextLabel?.text = row.subtitle; cell.detailTextLabel?.numberOfLines = 3; cell.detailTextLabel?.font = .preferredFont(forTextStyle: .caption1)
        cell.textLabel?.adjustsFontForContentSizeCategory = true; cell.detailTextLabel?.adjustsFontForContentSizeCategory = true
        cell.accessoryType = .disclosureIndicator
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let action = filtered[indexPath.row].action
        dismiss(animated: !UIAccessibility.isReduceMotionEnabled, completion: action)
    }
    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let row = filtered[indexPath.row]
        guard let remove = row.delete else { return nil }
        let delete = UIContextualAction(style: .destructive, title: "Remove") { [weak self] _, _, completed in
            let alert = UIAlertController(title: "Remove this item?", message: row.title, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completed(false) })
            alert.addAction(UIAlertAction(title: "Remove", style: .destructive) { [weak self] _ in
                // Dismiss first: operation errors can then be presented by BrowserController.
                self?.dismiss(animated: true) { remove() }; completed(true)
            })
            self?.present(alert, animated: true)
        }
        let configuration = UISwipeActionsConfiguration(actions: [delete]); configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }
}

final class DomainEditorController: UIViewController {
    private let text = UITextView()
    private let initial: String
    private let saveAction: (String) throws -> Void
    init(title: String, initial: String, save: @escaping (String) throws -> Void) {
        self.initial = initial; saveAction = save; super.init(nibName: nil, bundle: nil); self.title = title
    }
    required init?(coder: NSCoder) { fatalError("Storyboard construction is unsupported") }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .save, target: self, action: #selector(save))
        let label = UILabel(); label.text = "One ASCII/Punycode domain per line; no schemes or paths. Limit: 500. This is a user-provided list, not an automatically verified threat feed. Saving changes the active profile’s filtering rules."; label.numberOfLines = 0; label.font = .preferredFont(forTextStyle: .footnote)
        text.text = initial; text.font = .monospacedSystemFont(ofSize: 15, weight: .regular); text.autocapitalizationType = .none; text.autocorrectionType = .no; text.accessibilityLabel = "Domain list"
        text.smartQuotesType = .no; text.smartDashesType = .no
        for element in [label, text] { element.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(element) }
        NSLayoutConstraint.activate([label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16), label.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16), label.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16), text.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 12), text.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12), text.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12), text.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -12)])
    }
    @objc private func cancel() { dismiss(animated: true) }
    @objc private func save() {
        do {
            _ = try MobileShield.parse(text.text)
            let value = text.text ?? "", action = saveAction
            dismiss(animated: !UIAccessibility.isReduceMotionEnabled) { [weak self] in
                do { try action(value) }
                catch { let alert = UIAlertController(title: "Unable to save list", message: error.localizedDescription, preferredStyle: .alert); alert.addAction(UIAlertAction(title: "OK", style: .default)); self?.presentingViewController?.present(alert, animated: true) }
            }
        } catch {
            let alert = UIAlertController(title: "Invalid domain list", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default)); present(alert, animated: true)
        }
    }
}
