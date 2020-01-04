//  KeePassium Password Manager
//  Copyright © 2018–2019 Andrei Popleteev <info@keepassium.com>
// 
//  This program is free software: you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 3 as published
//  by the Free Software Foundation: https://www.gnu.org/licenses/).
//  For commercial licensing, please contact the author.

import UIKit
import KeePassiumLib

class UnlockDatabaseVC: UIViewController, Refreshable {
    @IBOutlet private weak var databaseNameLabel: UILabel!
    @IBOutlet private weak var inputPanel: UIView!
    @IBOutlet private weak var passwordField: UITextField!
    @IBOutlet private weak var keyFileField: UITextField!
    @IBOutlet private weak var keyboardAdjView: UIView!
    @IBOutlet private weak var errorMessagePanel: UIView!
    @IBOutlet private weak var errorLabel: UILabel!
    @IBOutlet private weak var errorDetailButton: UIButton!
    @IBOutlet private weak var watchdogTimeoutLabel: UILabel!
    @IBOutlet private weak var databaseIconImage: UIImageView!
    @IBOutlet weak var masterKeyKnownLabel: UILabel!
    @IBOutlet weak var getPremiumButton: UIButton!
    @IBOutlet weak var announcementButton: UIButton!
    
    public var databaseRef: URLReference! {
        didSet {
            guard isViewLoaded else { return }
            hideErrorMessage(animated: false)
            refresh()
        }
    }
    
    private var keyFileRef: URLReference?
    private var fileKeeperNotifications: FileKeeperNotifications!
    
    var isAutoUnlockEnabled = true
    fileprivate var isAutomaticUnlock = false

    static func make(databaseRef: URLReference) -> UnlockDatabaseVC {
        let vc = UnlockDatabaseVC.instantiateFromStoryboard()
        vc.databaseRef = databaseRef
        return vc
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        passwordField.delegate = self
        keyFileField.delegate = self
        
        fileKeeperNotifications = FileKeeperNotifications(observer: self)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshPremiumStatus),
            name: PremiumManager.statusUpdateNotification,
            object: nil)

        view.backgroundColor = UIColor(patternImage: UIImage(asset: .backgroundPattern))
        view.layer.isOpaque = false
        
        watchdogTimeoutLabel.alpha = 0.0
        errorMessagePanel.alpha = 0.0
        errorMessagePanel.isHidden = true

        passwordField.inputAssistantItem.leadingBarButtonGroups = []
        passwordField.inputAssistantItem.trailingBarButtonGroups = []
        
        let lockDatabaseButton = UIBarButtonItem(
            title: LString.actionCloseDatabase,
            style: .plain,
            target: nil,
            action: nil)
        navigationItem.backBarButtonItem = lockDatabaseButton
        
        refreshNews()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshPremiumStatus()
        refresh()
        if isMovingToParent && canAutoUnlock() {
            showProgressOverlay(animated: false)
        }
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        fileKeeperNotifications.startObserving()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onAppDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil)
        onAppDidBecomeActive()
        
        if isMovingToParent && canAutoUnlock() {
            DispatchQueue.main.async { [weak self] in
                self?.tryToUnlockDatabase(isAutomaticUnlock: true)
            }
        }

        if FileKeeper.shared.hasPendingFileOperations {
            processPendingFileOperations()
        }
        
        maybeFocusOnPassword()
    }
    
    @objc func onAppDidBecomeActive() {
        if Watchdog.shared.isDatabaseTimeoutExpired {
            showWatchdogTimeoutMessage()
        } else {
            hideWatchdogTimeoutMessage(animated: false)
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        NotificationCenter.default.removeObserver(
            self,
            name: UIApplication.didBecomeActiveNotification,
            object: nil)
        fileKeeperNotifications.stopObserving()
        super.viewWillDisappear(animated)
    }
    
    override func didReceiveMemoryWarning() {
        Diag.error("Received a memory warning")
        DatabaseManager.shared.progress.cancel(reason: .lowMemoryWarning)
    }
    
    func refresh() {
        guard isViewLoaded else { return }
        
        databaseIconImage.image = UIImage.databaseIcon(for: databaseRef)
        databaseNameLabel.text = databaseRef.info.fileName
        if databaseRef.info.hasError {
            let text = databaseRef.info.errorMessage
            if databaseRef.info.hasPermissionError257 {
                showErrorMessage(text, suggestion: LString.tryToReAddFile)
            } else {
                showErrorMessage(text)
            }
        }
        
        let associatedKeyFileRef = Settings.current
            .premiumGetKeyFileForDatabase(databaseRef: databaseRef)
        if let associatedKeyFileRef = associatedKeyFileRef {
            let allAvailableKeyFiles = FileKeeper.shared
                .getAllReferences(fileType: .keyFile, includeBackup: false)
            if let availableKeyFileRef = associatedKeyFileRef
                .find(in: allAvailableKeyFiles, fallbackToNamesake: true)
            {
                setKeyFile(urlRef: availableKeyFileRef)
            }
        }
        refreshNews()
        refreshInputMode()
    }
    
    @objc private func refreshPremiumStatus() {
        switch PremiumManager.shared.status {
        case .initialGracePeriod,
             .freeLightUse,
             .freeHeavyUse:
            getPremiumButton.isHidden = false
        case .subscribed,
             .lapsed:
            getPremiumButton.isHidden = true
        }
    }
    
    private func refreshInputMode() {
        let isDatabaseKeyStored = try? DatabaseManager.shared.hasKey(for: databaseRef)
        
        let shouldInputMasterKey = !(isDatabaseKeyStored ?? false)
        masterKeyKnownLabel.isHidden = shouldInputMasterKey
        inputPanel.isHidden = !shouldInputMasterKey
    }

    private func maybeFocusOnPassword() {
        if !inputPanel.isHidden {
            passwordField.becomeFirstResponder()
        }
    }
    
    
    private var newsItem: NewsItem?
    
    private func refreshNews() {
        let nc = NewsCenter.shared
        if let newsItem = nc.getTopItem() {
            announcementButton.titleLabel?.numberOfLines = 0
            announcementButton.setTitle(newsItem.title, for: .normal)
            announcementButton.isHidden = false
            self.newsItem = newsItem
        } else {
            announcementButton.isHidden = true
            self.newsItem = nil
        }
    }

    @IBAction func didPressAnouncementButton(_ sender: Any) {
        newsItem?.show(in: self)
    }
    

    func showErrorMessage(
        _ text: String?,
        details: String?=nil,
        suggestion: String?=nil,
        haptics: HapticFeedback.Kind?=nil
    ) {
        guard let text = text else { return }
        let message = [text, details, suggestion]
            .compactMap{ return $0 }
            .joined(separator: "\n")
        errorLabel.text = message
        Diag.error(message)
        UIAccessibility.post(notification: .layoutChanged, argument: errorLabel)
        
        guard errorMessagePanel.isHidden else { return }
        
        UIView.animate(
            withDuration: 0.3,
            delay: 0.0,
            options: .curveEaseIn,
            animations: {
                [weak self] in
                self?.errorMessagePanel.isHidden = false
                self?.errorMessagePanel.alpha = 1.0
            },
            completion: {
                [weak self] (finished) in
                self?.errorMessagePanel.shake()
                if let hapticsKind = haptics {
                    HapticFeedback.play(hapticsKind)
                }
            }
        )
    }
    
    func hideErrorMessage(animated: Bool) {
        guard !errorMessagePanel.isHidden else { return }

        if animated {
            UIView.animate(
                withDuration: 0.3,
                delay: 0.0,
                options: .curveEaseOut,
                animations: {
                    [weak self] in
                    self?.errorMessagePanel.alpha = 0.0
                    self?.errorMessagePanel.isHidden = true
                },
                completion: {
                    [weak self] (finished) in
                    self?.errorLabel.text = nil
                }
            )
        } else {
            errorMessagePanel.isHidden = true
            errorLabel.text = nil
        }
    }
    
    func showWatchdogTimeoutMessage() {
        UIView.animate(
            withDuration: 0.5,
            delay: 0.0,
            options: .curveEaseOut,
            animations: {
                [weak self] in
                self?.watchdogTimeoutLabel.alpha = 1.0
            },
            completion: nil)
    }
    
    func hideWatchdogTimeoutMessage(animated: Bool) {
        if animated {
            UIView.animate(
                withDuration: 0.5,
                delay: 0.0,
                options: .curveEaseOut,
                animations: {
                    [weak self] in
                    self?.watchdogTimeoutLabel.alpha = 0.0
                },
                completion: nil)
        } else {
            watchdogTimeoutLabel.alpha = 0.0
        }
    }

    private var progressOverlay: ProgressOverlay?
    fileprivate func showProgressOverlay(animated: Bool) {
        guard progressOverlay == nil else { return }
        progressOverlay = ProgressOverlay.addTo(
            keyboardAdjView,
            title: LString.databaseStatusLoading,
            animated: animated)
        progressOverlay?.isCancellable = true
        
        if let leftNavController = splitViewController?.viewControllers.first as? UINavigationController,
            let chooseDatabaseVC = leftNavController.topViewController as? ChooseDatabaseVC {
                chooseDatabaseVC.isEnabled = false
        }
        navigationItem.hidesBackButton = true
    }
    
    fileprivate func hideProgressOverlay(quickly: Bool) {
        UIView.animateKeyframes(
            withDuration: quickly ? 0.2 : 0.6,
            delay: quickly ? 0.0 : 0.6,
            options: [.beginFromCurrentState],
            animations: {
                [weak self] in
                self?.progressOverlay?.alpha = 0.0
            },
            completion: {
                [weak self] finished in
                guard let _self = self else { return }
                _self.progressOverlay?.removeFromSuperview()
                _self.progressOverlay = nil
            }
        )
        navigationItem.hidesBackButton = false
        if let leftNavController = splitViewController?.viewControllers.first as? UINavigationController,
            let chooseDatabaseVC = leftNavController.topViewController as? ChooseDatabaseVC {
            chooseDatabaseVC.isEnabled = true
        }

        let p = DatabaseManager.shared.progress
        Diag.verbose("Final progress: \(p.completedUnitCount) of \(p.totalUnitCount)")
    }

    
    func selectKeyFileAction(_ sender: Any) {
        Diag.verbose("Selecting key file")
        hideErrorMessage(animated: true)
        let keyFileChooser = ChooseKeyFileVC.make(popoverSourceView: keyFileField, delegate: self)
        present(keyFileChooser, animated: true, completion: nil)
    }
    
    
    @IBAction func didPressErrorDetails(_ sender: Any) {
        let diagInfoVC = ViewDiagnosticsVC.make()
        present(diagInfoVC, animated: true, completion: nil)
    }
    
    @IBAction func didPressUnlock(_ sender: Any) {
        tryToUnlockDatabase(isAutomaticUnlock: false)
    }
    
    private var premiumCoordinator: PremiumCoordinator?
    @IBAction func didPressUpgradeToPremium(_ sender: Any) {
        assert(premiumCoordinator == nil)
        premiumCoordinator = PremiumCoordinator(presentingViewController: self)
        premiumCoordinator?.delegate = self
        premiumCoordinator?.start()
    }
    
    
    func canAutoUnlock() -> Bool {
        guard isAutoUnlockEnabled else { return false }
        guard let splitVC = splitViewController, splitVC.isCollapsed else { return false }
        let hasKey: Bool = (try? DatabaseManager.shared.hasKey(for: databaseRef)) ?? true
        return hasKey
    }
    
    func tryToUnlockDatabase(isAutomaticUnlock: Bool) {
        Diag.clear()
        self.isAutomaticUnlock = isAutomaticUnlock
        let password = passwordField.text ?? ""
        passwordField.resignFirstResponder()
        hideWatchdogTimeoutMessage(animated: true)
        DatabaseManager.shared.addObserver(self)
        
        do {
            if let databaseKey = try Keychain.shared.getDatabaseKey(databaseRef: databaseRef) {
                DatabaseManager.shared.startLoadingDatabase(
                    database: databaseRef,
                    compositeKey: databaseKey)
            } else {
                DatabaseManager.shared.startLoadingDatabase(
                    database: databaseRef,
                    password: password,
                    keyFile: keyFileRef)
            }
        } catch {
            Diag.error(error.localizedDescription)
            hideProgressOverlay(quickly: true) 
            showErrorMessage(error.localizedDescription)
        }
    }
    
    func showDatabaseRoot(loadingWarnings: DatabaseLoadingWarnings) {
        guard let database = DatabaseManager.shared.database else {
            assertionFailure()
            return
        }
        let viewGroupVC = ViewGroupVC.make(group: database.root, loadingWarnings: loadingWarnings)
        guard let leftNavController =
            splitViewController?.viewControllers.first as? UINavigationController else
        {
            fatalError("No leftNavController?!")
        }
        if leftNavController.topViewController is UnlockDatabaseVC {
            var viewControllers = leftNavController.viewControllers
            viewControllers[viewControllers.count - 1] = viewGroupVC
            leftNavController.setViewControllers(viewControllers, animated: true)
        } else {
            leftNavController.show(viewGroupVC, sender: self)
        }
    }
}

extension UnlockDatabaseVC: KeyFileChooserDelegate {
    func setKeyFile(urlRef: URLReference?) {
        keyFileRef = urlRef
        Settings.current.setKeyFileForDatabase(databaseRef: databaseRef, keyFileRef: keyFileRef)

        guard let fileInfo = urlRef?.info else {
            Diag.debug("No key file selected")
            keyFileField.text = ""
            return
        }
        if let errorDetails = fileInfo.errorMessage {
            let errorMessage = String.localizedStringWithFormat(
                NSLocalizedString(
                    "[Database/Unlock] Key file error: %@",
                    value: "Key file error: %@",
                    comment: "Error message related to key file. [errorDetails: String]"),
                errorDetails)
            Diag.warning(errorMessage)
            showErrorMessage(errorMessage)
            keyFileField.text = ""
        } else {
            Diag.info("Key file set successfully")
            keyFileField.text = fileInfo.fileName
        }
    }
    
    func onKeyFileSelected(urlRef: URLReference?) {
        setKeyFile(urlRef: urlRef)
    }
}

extension UnlockDatabaseVC: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField == self.passwordField {
            tryToUnlockDatabase(isAutomaticUnlock: false)
        }
        return true
    }
    
    func textField(
        _ textField: UITextField,
        shouldChangeCharactersIn range: NSRange,
        replacementString string: String) -> Bool
    {
        hideErrorMessage(animated: true)
        hideWatchdogTimeoutMessage(animated: true)
        return true
    }
    
    func textFieldShouldBeginEditing(_ textField: UITextField) -> Bool {
        if textField === keyFileField {
            passwordField.becomeFirstResponder()
            selectKeyFileAction(textField)
            return false
        }
        return true
    }
    
    func textFieldDidBeginEditing(_ textField: UITextField) {
    }
}


extension UnlockDatabaseVC: DatabaseManagerObserver {
    func databaseManager(willLoadDatabase urlRef: URLReference) {
        self.passwordField.text = "" 
        showProgressOverlay(animated: true)
    }
    
    func databaseManager(database urlRef: URLReference, isCancelled: Bool) {
        DatabaseManager.shared.removeObserver(self)
        try? Keychain.shared.removeDatabaseKey(databaseRef: urlRef) 
        refresh()
        hideProgressOverlay(quickly: true)
        maybeFocusOnPassword()
    }
    
    func databaseManager(progressDidChange progress: ProgressEx) {
        progressOverlay?.update(with: progress)
    }
    
    func databaseManager(database urlRef: URLReference, invalidMasterKey message: String) {
        DatabaseManager.shared.removeObserver(self)
        try? Keychain.shared.removeDatabaseKey(databaseRef: urlRef) 
        refresh()
        hideProgressOverlay(quickly: true)
        
        showErrorMessage(message, haptics: .wrongPassword)
        maybeFocusOnPassword()
    }
    
    func databaseManager(didLoadDatabase urlRef: URLReference, warnings: DatabaseLoadingWarnings) {
        DatabaseManager.shared.removeObserver(self)
        
        HapticFeedback.play(.databaseUnlocked)
        
        if Settings.current.isRememberDatabaseKey {
            do {
                try DatabaseManager.shared.rememberDatabaseKey() 
            } catch {
                Diag.error("Failed to remember database key [message: \(error.localizedDescription)]")
            }
        }
        hideProgressOverlay(quickly: false)
        showDatabaseRoot(loadingWarnings: warnings)
    }

    func databaseManager(database urlRef: URLReference, loadingError message: String, reason: String?) {
        DatabaseManager.shared.removeObserver(self)
        refresh()
        hideProgressOverlay(quickly: true)
        
        isAutoUnlockEnabled = false
        showErrorMessage(message, details: reason, haptics: .error)
        maybeFocusOnPassword()
    }
}

extension UnlockDatabaseVC: FileKeeperObserver {
    func fileKeeper(didAddFile urlRef: URLReference, fileType: FileType) {
        if fileType == .database {
            navigationController?.popViewController(animated: true)
        }
    }

    func fileKeeperHasPendingOperation() {
        processPendingFileOperations()
    }

    private func processPendingFileOperations() {
        FileKeeper.shared.processPendingOperations(
            success: nil,
            error: {
                [weak self] (error) in
                guard let _self = self else { return }
                let alert = UIAlertController.make(
                    title: LString.titleError,
                    message: error.localizedDescription)
                _self.present(alert, animated: true, completion: nil)
            }
        )
    }
}

extension UnlockDatabaseVC: PremiumCoordinatorDelegate {
    func didUpgradeToPremium(in premiumCoordinator: PremiumCoordinator) {
        refresh()
    }
    
    func didFinish(_ premiumCoordinator: PremiumCoordinator) {
        self.premiumCoordinator = nil
    }
}
