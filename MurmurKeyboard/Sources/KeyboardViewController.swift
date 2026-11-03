import UIKit
import MurmurCore

class KeyboardViewController: UIInputViewController {
    
    private var stackView: UIStackView!
    private var micButton: UIButton!
    private var textLabel: UILabel!
    private var pendingTranscription: String?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        checkForPendingTranscription()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        checkForPendingTranscription()
    }
    
    private func setupUI() {
        view.backgroundColor = UIColor(red: 0.82, green: 0.84, blue: 0.86, alpha: 1.0)
        
        stackView = UIStackView()
        stackView.axis = .vertical
        stackView.spacing = 8
        stackView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stackView)
        
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            stackView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            stackView.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            stackView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8)
        ])
        
        let topRow = createTopRow()
        stackView.addArrangedSubview(topRow)
        
        let mainRow = createMainRow()
        stackView.addArrangedSubview(mainRow)
        
        let bottomRow = createBottomRow()
        stackView.addArrangedSubview(bottomRow)
    }
    
    private func createTopRow() -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 6
        row.distribution = .fillEqually
        
        let keys = ["Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P"]
        for key in keys {
            let button = createKeyButton(title: key)
            button.addTarget(self, action: #selector(keyTapped(_:)), for: .touchUpInside)
            row.addArrangedSubview(button)
        }
        
        return row
    }
    
    private func createMainRow() -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .center
        
        micButton = UIButton(type: .system)
        micButton.setImage(UIImage(systemName: "mic.fill"), for: .normal)
        micButton.tintColor = .white
        micButton.backgroundColor = .systemBlue
        micButton.layer.cornerRadius = 30
        micButton.translatesAutoresizingMaskIntoConstraints = false
        micButton.addTarget(self, action: #selector(micButtonTapped), for: .touchUpInside)
        
        NSLayoutConstraint.activate([
            micButton.widthAnchor.constraint(equalToConstant: 60),
            micButton.heightAnchor.constraint(equalToConstant: 60)
        ])
        
        let middleKeys = UIStackView()
        middleKeys.axis = .horizontal
        middleKeys.spacing = 6
        middleKeys.distribution = .fillEqually
        
        let keys = ["A", "S", "D", "F", "G", "H", "J", "K", "L"]
        for key in keys {
            let button = createKeyButton(title: key)
            button.addTarget(self, action: #selector(keyTapped(_:)), for: .touchUpInside)
            middleKeys.addArrangedSubview(button)
        }
        
        row.addArrangedSubview(micButton)
        row.addArrangedSubview(middleKeys)
        
        return row
    }
    
    private func createBottomRow() -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 6
        row.distribution = .fill
        
        let globeButton = UIButton(type: .system)
        globeButton.setImage(UIImage(systemName: "globe"), for: .normal)
        globeButton.tintColor = .darkGray
        globeButton.backgroundColor = UIColor(white: 0.7, alpha: 1.0)
        globeButton.layer.cornerRadius = 5
        globeButton.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        globeButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            globeButton.widthAnchor.constraint(equalToConstant: 40)
        ])
        
        let spaceButton = createKeyButton(title: "space")
        spaceButton.addTarget(self, action: #selector(spaceTapped), for: .touchUpInside)
        
        let returnButton = createKeyButton(title: "return")
        returnButton.backgroundColor = .systemBlue
        returnButton.setTitleColor(.white, for: .normal)
        returnButton.addTarget(self, action: #selector(returnTapped), for: .touchUpInside)
        returnButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            returnButton.widthAnchor.constraint(equalToConstant: 80)
        ])
        
        let deleteButton = UIButton(type: .system)
        deleteButton.setImage(UIImage(systemName: "delete.left"), for: .normal)
        deleteButton.tintColor = .darkGray
        deleteButton.backgroundColor = UIColor(white: 0.7, alpha: 1.0)
        deleteButton.layer.cornerRadius = 5
        deleteButton.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            deleteButton.widthAnchor.constraint(equalToConstant: 40)
        ])
        
        row.addArrangedSubview(globeButton)
        row.addArrangedSubview(spaceButton)
        row.addArrangedSubview(returnButton)
        row.addArrangedSubview(deleteButton)
        
        return row
    }
    
    private func createKeyButton(title: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.setTitleColor(.black, for: .normal)
        button.backgroundColor = .white
        button.layer.cornerRadius = 5
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOffset = CGSize(width: 0, height: 1)
        button.layer.shadowOpacity = 0.3
        button.layer.shadowRadius = 0
        button.titleLabel?.font = UIFont.systemFont(ofSize: 22)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 42).isActive = true
        return button
    }
    
    @objc private func keyTapped(_ sender: UIButton) {
        guard let key = sender.title(for: .normal) else { return }
        textDocumentProxy.insertText(key)
        
        UIDevice.current.playInputClick()
    }
    
    @objc private func spaceTapped() {
        textDocumentProxy.insertText(" ")
        UIDevice.current.playInputClick()
    }
    
    @objc private func returnTapped() {
        textDocumentProxy.insertText("\n")
        UIDevice.current.playInputClick()
    }
    
    @objc private func deleteTapped() {
        textDocumentProxy.deleteBackward()
        UIDevice.current.playInputClick()
    }
    
    @objc private func micButtonTapped() {
        guard hasFullAccess else {
            showFullAccessAlert()
            return
        }
        
        openMurmurApp()
    }
    
    private func openMurmurApp() {
        guard let url = URL(string: "murmur://record") else { return }
        
        var responder: UIResponder? = self
        while let nextResponder = responder?.next {
            if let application = nextResponder as? UIApplication {
                application.open(url, options: [:], completionHandler: nil)
                return
            }
            responder = nextResponder
        }
        
        extensionContext?.open(url, completionHandler: nil)
    }
    
    private func checkForPendingTranscription() {
        guard let url = MurmurCore.sharedTranscriptionURL(),
              FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            if !text.isEmpty {
                textDocumentProxy.insertText(text)
                try FileManager.default.removeItem(at: url)
                
                UIDevice.current.playInputClick()
            }
        } catch {
            print("Failed to read transcription: \(error)")
        }
    }
    
    private var hasFullAccess: Bool {
        return UIPasteboard.general.hasStrings || UIPasteboard.general.hasImages || true
    }
    
    private func showFullAccessAlert() {
        micButton.backgroundColor = .systemRed
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.micButton.backgroundColor = .systemBlue
        }
    }
}

extension KeyboardViewController: UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool {
        return true
    }
}
