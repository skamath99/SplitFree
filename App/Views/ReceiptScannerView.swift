import SwiftUI
import PhotosUI
import Vision
import SplitCore

enum ReceiptScanResult {
    /// Line items to prefill the itemization editor, plus the bill total
    /// (tax/tip = total − items, spread proportionally by the editor).
    case itemized(items: [ScannedItem], total: Decimal)
    case total(Decimal)
}

/// Receipt scanning — a Splitwise Pro feature, free here via on-device Vision
/// OCR. Reads the line items off a receipt photo so each dish can be assigned
/// to whoever ordered it (no cloud, no upload). Falls back to just the total.
struct ReceiptScannerView: View {
    @Environment(\.dismiss) private var dismiss
    let onResult: (ReceiptScanResult) -> Void

    @State private var selectedItem: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var receipt: ScannedReceipt?
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
                        .frame(maxHeight: receipt?.items.isEmpty == false ? 120 : 260)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                PhotosPicker(selection: $selectedItem, matching: .images) {
                    Label(image == nil ? "Choose receipt photo" : "Choose a different photo",
                          systemImage: "photo.on.rectangle")
                }
                .buttonStyle(.bordered)

                if isScanning {
                    ProgressView("Reading receipt…")
                } else if let receipt, !receipt.items.isEmpty {
                    itemsList(receipt)
                } else if !candidates.isEmpty {
                    totalsList
                } else if let errorMessage {
                    Text(errorMessage).foregroundStyle(.secondary).padding()
                } else if image == nil {
                    ContentUnavailableView("Scan a receipt", systemImage: "doc.text.viewfinder",
                                           description: Text("The line items are read off the photo so you can assign each one to whoever ordered it. Everything runs on-device with Apple's Vision framework — the photo never leaves your phone."))
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

    private func itemsList(_ receipt: ScannedReceipt) -> some View {
        List {
            Section {
                ForEach(Array(receipt.items.enumerated()), id: \.offset) { _, item in
                    HStack {
                        Text(item.name)
                        Spacer()
                        Text(item.amount.formatted(.number.precision(.fractionLength(2))))
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("\(receipt.items.count) items found")
            } footer: {
                Text(footerText(for: receipt))
            }

            Section {
                Button {
                    onResult(.itemized(items: receipt.items, total: receipt.effectiveTotal))
                    dismiss()
                } label: {
                    Label("Use these items", systemImage: "list.bullet.indent")
                        .font(.body.weight(.semibold))
                }
                Button {
                    onResult(.total(receipt.effectiveTotal))
                    dismiss()
                } label: {
                    Label("Just use the total (\(receipt.effectiveTotal.formatted(.number.precision(.fractionLength(2)))))",
                          systemImage: "sum")
                }
            } footer: {
                Text("You can fix names and prices in the item editor before assigning people.")
            }
        }
        .listStyle(.insetGrouped)
    }

    private var totalsList: some View {
        List {
            Section {
                ForEach(candidates, id: \.self) { candidate in
                    Button {
                        onResult(.total(candidate))
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
            } header: {
                Text("Tap the total")
            } footer: {
                Text("No line items could be read off this photo, but these amounts were.")
            }
        }
        .listStyle(.insetGrouped)
    }

    private func footerText(for receipt: ScannedReceipt) -> String {
        var parts: [String] = ["Items \(receipt.itemsSum.formatted(.number.precision(.fractionLength(2))))"]
        if let tax = receipt.tax { parts.append("tax \(tax.formatted(.number.precision(.fractionLength(2))))") }
        if let tip = receipt.tip { parts.append("tip \(tip.formatted(.number.precision(.fractionLength(2))))") }
        parts.append("total \(receipt.effectiveTotal.formatted(.number.precision(.fractionLength(2))))")
        return parts.joined(separator: " · ") + ". Tax and tip get split proportionally to what each person ordered."
    }

    private func scan() async {
        guard let selectedItem else { return }
        isScanning = true
        errorMessage = nil
        receipt = nil
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

        let observations = request.results ?? []
        // Vision's normalized coordinates put the origin bottom-left; flip y
        // so the parser reads rows top-to-bottom.
        let lines: [ScannedLine] = observations.compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let box = observation.boundingBox
            return ScannedLine(text: text,
                               x: box.minX,
                               y: 1 - box.midY,
                               height: box.height)
        }
        let parsed = ReceiptParser.parse(lines: lines)
        if !parsed.items.isEmpty {
            receipt = parsed
        } else {
            candidates = ReceiptParser.totals(from: lines.map(\.text))
            if candidates.isEmpty {
                errorMessage = "No amounts found — try a clearer photo."
            }
        }
    }
}
