import SwiftUI
import SwiftData
import PhotosUI

#if os(iOS)
import UIKit
#endif

struct FoodPhotoSheet: View {
    let mealType: MealType
    let date: Date
    var addToMyFoods: Bool = false
    let onLogged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(FoodRecognitionEnvironment.self) private var env
    @Query private var dayLogs: [DayLog]
    @Query private var cachedFoods: [CachedFood]

    @State private var stage: Stage = .pickSource
    @State private var image: UIImage?
    @State private var imageData: Data?
    @State private var description: String = ""
    @State private var pickerItem: PhotosPickerItem?
    @State private var errorMessage: String?

    @State private var showCameraPicker = false

    // Editable recognized fields
    @State private var nameText: String = ""
    @State private var brandText: String = ""
    @State private var portionText: String = ""
    @State private var caloriesText: String = ""
    @State private var proteinText: String = ""
    @State private var carbsText: String = ""
    @State private var fatText: String = ""
    @State private var confidenceLabel: String?
    @State private var notesText: String?
    @State private var recognizedServingGrams: Double?

    enum Stage: Equatable {
        case pickSource
        case ready
        case analyzing
        case result
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Analyze Photo")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { dismiss() }
                    }
                }
                #if os(iOS)
                .fullScreenCover(isPresented: $showCameraPicker) {
                    CameraPicker(
                        onImage: { img in
                            showCameraPicker = false
                            useImage(img)
                        },
                        onCancel: { showCameraPicker = false }
                    )
                    .ignoresSafeArea()
                }
                #endif
                .onChange(of: pickerItem) { _, newItem in
                    guard let newItem else { return }
                    Task { await loadPickerItem(newItem) }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch stage {
        case .pickSource:
            pickSourceView
        case .ready:
            readyView
        case .analyzing:
            analyzingView
        case .result:
            resultView
        }
    }

    // MARK: - Stage: pick

    private var pickSourceView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "camera.metering.center.weighted")
                .font(.system(size: 72, weight: .light))
                .foregroundStyle(.tint)
            Text("Snap a meal, get an estimate")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Text("Claude will look at the photo and estimate the food name, portion, and macros. You can edit anything before logging.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()

            VStack(spacing: 10) {
                #if os(iOS)
                Button {
                    showCameraPicker = true
                } label: {
                    Label("Take photo", systemImage: "camera.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                #endif

                PhotosPicker(
                    selection: $pickerItem,
                    matching: .images,
                    preferredItemEncoding: .automatic
                ) {
                    Label("Choose from library", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(.horizontal)
            .padding(.bottom, 20)
        }
    }

    // MARK: - Stage: ready

    private var readyView: some View {
        Form {
            if let image {
                Section {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 240)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .listRowInsets(EdgeInsets())
                }
            }

            Section {
                TextField("Describe the food in the photo", text: $description, axis: .vertical)
                    .lineLimit(2...6)
                    .textInputAutocapitalization(.sentences)
            } header: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").foregroundStyle(.tint)
                    Text("AI description")
                }
            } footer: {
                Text("Optional — add a description of what's in the photo to help the AI analyze the image and return a more accurate result.")
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }

            Section {
                Button { Task { await analyze() } } label: {
                    Text("Analyze")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button("Pick a different photo") { resetToPick() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.footnote)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Stage: analyzing

    private var analyzingView: some View {
        VStack(spacing: 16) {
            Spacer()
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.15)))
                    .padding(.horizontal)
            }
            ProgressView()
                .controlSize(.large)
            Text("Claude is analyzing your photo…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Stage: result

    private var resultView: some View {
        Form {
            if let image {
                Section {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 180)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .listRowInsets(EdgeInsets())
                }
            }

            if confidenceLabel != nil || notesText != nil {
                Section {
                    if let confidenceLabel {
                        HStack {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.tint)
                            Text("Claude's confidence: \(confidenceLabel)")
                                .font(.footnote)
                        }
                    }
                    if let notesText, !notesText.isEmpty {
                        Text(notesText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                TextField("Name", text: $nameText)
                    .textInputAutocapitalization(.words)
                TextField("Brand (optional)", text: $brandText)
                    .textInputAutocapitalization(.words)
                TextField("Portion", text: $portionText)
            } footer: {
                Text("Edit anything that looks off before logging.")
            }

            Section("Nutrition") {
                field(label: "Calories", text: $caloriesText, suffix: "kcal")
                field(label: "Protein", text: $proteinText, suffix: "g")
                field(label: "Carbs", text: $carbsText, suffix: "g")
                field(label: "Fat", text: $fatText, suffix: "g")
            }

            Section {
                Button {
                    save()
                } label: {
                    Label(
                        addToMyFoods ? "Save to My Foods" : "Add to \(mealType.displayName)",
                        systemImage: addToMyFoods ? "checkmark.circle.fill" : "plus.circle.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(Double(caloriesText) == nil || nameText.trimmingCharacters(in: .whitespaces).isEmpty)

                Button("Analyze again") {
                    stage = .ready
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func field(label: String, text: Binding<String>, suffix: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("0", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(maxWidth: 100)
            Text(suffix)
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)
        }
    }

    // MARK: - Actions

    private func loadPickerItem(_ item: PhotosPickerItem) async {
        errorMessage = nil
        do {
            if let data = try await item.loadTransferable(type: Data.self),
               let uiImage = UIImage(data: data) {
                useImage(uiImage)
            }
        } catch {
            errorMessage = "Couldn't load that photo — try another."
        }
    }

    private func useImage(_ uiImage: UIImage) {
        #if os(iOS)
        let scaled = uiImage.scaled(toMaxDimension: 1024)
        let data = scaled.jpegData(compressionQuality: 0.75) ?? uiImage.jpegData(compressionQuality: 0.75)
        image = scaled
        imageData = data
        stage = .ready
        errorMessage = nil
        #else
        image = uiImage
        imageData = uiImage.jpegData(compressionQuality: 0.75)
        stage = .ready
        #endif
    }

    private func resetToPick() {
        image = nil
        imageData = nil
        pickerItem = nil
        description = ""
        recognizedServingGrams = nil
        errorMessage = nil
        stage = .pickSource
    }

    private func analyze() async {
        guard let imageData else { return }
        stage = .analyzing
        errorMessage = nil
        do {
            let meal = try await env.service.recognize(
                imageData: imageData,
                hint: description.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            )
            prefill(from: meal)
            stage = .result
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            stage = .ready
        }
    }

    private func prefill(from meal: RecognizedMeal) {
        nameText = meal.name
        brandText = ""
        recognizedServingGrams = meal.servingGrams
        caloriesText = String(Int(meal.caloriesPerServing.rounded()))
        proteinText = String(format: "%.1f", meal.proteinPerServing)
        carbsText = String(format: "%.1f", meal.carbsPerServing)
        fatText = String(format: "%.1f", meal.fatPerServing)
        confidenceLabel = meal.confidence.flatMap { $0.isEmpty ? nil : $0 }

        // Recipe-like portions belong in Notes, not in the serving label — keep the serving
        // generic so the row reads "1 serving" while the full description is preserved below.
        let portionRaw = meal.portionDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let aiCaveat = meal.notes.flatMap { $0.isEmpty ? nil : $0 }
        if RecognizedMeal.looksLikeRecipeExplanation(portionRaw) {
            portionText = "1 serving"
            notesText = [portionRaw, aiCaveat].compactMap { $0 }.joined(separator: "\n")
        } else {
            portionText = portionRaw
            notesText = aiCaveat
        }
    }

    private func save() {
        guard let cals = Double(caloriesText), cals > 0 else { return }
        let trimmedName = nameText.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }
        let trimmedBrandRaw = brandText.trimmingCharacters(in: .whitespaces)
        let trimmedBrand: String? = trimmedBrandRaw.isEmpty ? nil : trimmedBrandRaw
        let trimmedPortion = portionText.trimmingCharacters(in: .whitespaces)
        let useEach = RecognizedMeal.shouldUseEachServing(
            name: trimmedName,
            portionDescription: trimmedPortion,
            userText: description
        )

        let protein = Double(proteinText) ?? 0
        let carbs = Double(carbsText) ?? 0
        let fat = Double(fatText) ?? 0
        let externalId = "photo:\(UUID().uuidString)"
        let storedNotes: String? = notesText.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }

        // Resolve native unit from the AI's portion text. Composite plates ("burger and fries")
        // collapse to "ea". A clean "1 bar" / "1 burger" parses to its noun. Recognized grams
        // become per-native grams.
        let (nativeUnit, nativeUnitGrams) = resolveNative(
            portion: trimmedPortion,
            useEach: useEach,
            recognizedGrams: recognizedServingGrams
        )

        if !addToMyFoods {
            let log = ensureDayLog()
            let entry = FoodEntry(
                name: trimmedName,
                brand: trimmedBrand,
                nativeUnit: nativeUnit,
                nativeUnitGrams: nativeUnitGrams,
                nativeUnitMilliliters: nil,
                selectedUnit: nativeUnit,
                quantity: 1,
                caloriesPerServing: cals,
                proteinPerServing: protein,
                carbsPerServing: carbs,
                fatPerServing: fat,
                mealType: mealType,
                source: .photo,
                externalId: externalId,
                notes: storedNotes,
                timestamp: Date(),
                dayLog: log
            )
            modelContext.insert(entry)
        }
        upsertCached(
            externalId: externalId,
            name: trimmedName,
            brand: trimmedBrand,
            nativeUnit: nativeUnit,
            nativeUnitGrams: nativeUnitGrams,
            calories: cals,
            protein: protein,
            carbs: carbs,
            fat: fat,
            notes: storedNotes
        )
        try? modelContext.save()
        dismiss()
        onLogged()
    }

    /// Parse the AI's portion description ("1 bar", "1 burger") into a native unit token + per-
    /// native gram weight. Falls back to "ea" for composite/recipe-style portions where no clean
    /// unit noun is available.
    private func resolveNative(portion: String, useEach: Bool, recognizedGrams: Double?) -> (String, Double?) {
        if useEach || RecognizedMeal.looksLikeRecipeExplanation(portion) {
            return ("ea", nil)
        }
        guard let parsed = ServingMath.parseServingDescription(portion),
              parsed.count > 0,
              !parsed.unit.isEmpty else {
            return ("ea", nil)
        }
        let token = ServingMath.normalizeUnitToken(parsed.unit)
        if token.isEmpty || ServingMath.isMeasurementUnit(token) {
            return ("ea", nil)
        }
        let perNative = recognizedGrams.map { $0 / parsed.count }
        return (token, perNative)
    }

    private func upsertCached(
        externalId: String,
        name: String,
        brand: String?,
        nativeUnit: String,
        nativeUnitGrams: Double?,
        calories: Double,
        protein: Double,
        carbs: Double,
        fat: Double,
        notes: String?
    ) {
        if let existing = cachedFoods.first(where: { $0.externalId == externalId }) {
            existing.lastUsed = .now
            if !addToMyFoods { existing.useCount += 1 }
            existing.lastSelectedUnit = nativeUnit
            existing.lastSelectedQuantity = 1
            if addToMyFoods { existing.isInMyFoods = true }
        } else {
            let cached = CachedFood(
                externalId: externalId,
                name: name,
                brand: brand,
                nativeUnit: nativeUnit,
                nativeUnitGrams: nativeUnitGrams,
                nativeUnitMilliliters: nil,
                lastSelectedUnit: nativeUnit,
                lastSelectedQuantity: 1,
                caloriesPerServing: calories,
                proteinPerServing: protein,
                carbsPerServing: carbs,
                fatPerServing: fat,
                source: .photo,
                isInMyFoods: addToMyFoods,
                lastUsed: .now,
                useCount: addToMyFoods ? 0 : 1,
                notes: notes
            )
            modelContext.insert(cached)
        }
        trimRecents(limit: 100)
    }

    private func trimRecents(limit: Int) {
        let descriptor = FetchDescriptor<CachedFood>(
            predicate: #Predicate<CachedFood> { $0.isFavorite == false && $0.isInMyFoods == false },
            sortBy: [SortDescriptor(\.lastUsed, order: .reverse)]
        )
        guard let recentNonFavorites = try? modelContext.fetch(descriptor),
              recentNonFavorites.count > limit else { return }

        for cached in recentNonFavorites.dropFirst(limit) {
            modelContext.delete(cached)
        }
    }

    private func ensureDayLog() -> DayLog {
        let day = Calendar.current.startOfDay(for: date)
        if let existing = DayLog.preferredForDay(dayLogs, on: day) {
            return existing
        }
        let new = DayLog(date: day)
        modelContext.insert(new)
        return new
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
