import SwiftUI
import PhotosUI
import Vision

/// Receipt scanning — a Splitwise Pro feature, free here via on-device Vision
/// OCR. Pick a receipt photo; we find the total (no cloud, no upload).
struct ReceiptScannerView: View {
    @Environment(\.dismiss) private var dismiss
    let onTotalFound: (Decimal) -> Void

    @State private var selectedItem: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var candidates: [Decimal] = []
    @State private var isScanning = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                PhotosPicker(selection: $selectedItem, matching: .images) {
                    Label(image == nil ? "Choose receipt photo" : "Choose a different photo",
                          systemImage: "photo.on.rectangle")
                }
                .buttonStyle(.bordered)

                if isScanning {
                    ProgressView("Reading receipt…")
                } else if !candidates.isEmpty {
                    List {
                        Section("Tap the total") {
                            ForEach(candidates, id: \.self) { candidate in
                                Button {
                                    onTotalFound(candidate)
                                    dismiss()
                                } label: {
                                    HStack {
                                        Text(candidate.formatted(.number.precision(.fractionLength(2))))
                                            .font(.body.weight(.medium))
                                        if candidate == candidates.first {
                                            Text("likely total")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "arrow.down.left.circle")
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                } else if let errorMessage {
                    Text(errorMessage).foregroundStyle(.secondary).padding()
                } else if image == nil {
                    ContentUnavailableView("Scan a receipt", systemImage: "doc.text.viewfinder",
                                           description: Text("Everything runs on-device with Apple's Vision framework. The photo never leaves your phone."))
                }
                Spacer(minLength: 0)
            }
            .padding(.top)
            .navigationTitle("Receipt scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onChange(of: selectedItem) {
                Task { await scan() }
            }
        }
    }

    private func scan() async {
        guard let selectedItem else { return }
        isScanning = true
        errorMessage = nil
        candidates = []
        defer { isScanning = false }

        guard let data = try? await selectedItem.loadTransferable(type: Data.self),
              let uiImage = UIImage(data: data),
              let cgImage = uiImage.cgImage else {
            errorMessage = "Couldn't load that photo."
            return
        }
        image = uiImage

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            errorMessage = "Text recognition failed: \(error.localizedDescription)"
            return
        }

        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        candidates = ReceiptParser.totals(from: lines)
        if candidates.isEmpty {
            errorMessage = "No amounts found — try a clearer photo."
        }
    }
}

enum ReceiptParser {
    /// Pulls money-looking values out of OCR lines, ranked with lines that
    /// mention "total" first, then by amount descending.
    static func totals(from lines: [String]) -> [Decimal] {
        let regex = /(\d{1,6}[.,]\d{2})/
        var totalLineAmounts: [Decimal] = []
        var otherAmounts: [Decimal] = []
        for line in lines {
            let isTotalLine = line.localizedCaseInsensitiveContains("total")
                && !line.localizedCaseInsensitiveContains("subtotal")
            for match in line.matches(of: regex) {
                let normalized = match.1.replacing(",", with: ".")
                guard let value = Decimal(string: String(normalized)), value > 0 else { continue }
                if isTotalLine {
                    totalLineAmounts.append(value)
                } else {
                    otherAmounts.append(value)
                }
            }
        }
        var seen = Set<Decimal>()
        let ranked = totalLineAmounts.sorted(by: >) + otherAmounts.sorted(by: >)
        return ranked.filter { seen.insert($0).inserted }
    }
}
