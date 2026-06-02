import SwiftUI
import PhotosUI

#if os(iOS)
import UIKit
#endif

/// Photo-based food recognition. The user snaps/picks an image (optionally adds a hint), Claude
/// recognizes the food, and the sheet hands the estimate back as a `FoodSearchResult` so the
/// normal portion sheet handles portion tweaks, My Foods/staple toggles, and logging — keeping
/// the photo flow identical to the Describe-with-AI flow.
struct FoodPhotoSheet: View {
    let onEstimated: (FoodSearchResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(FoodRecognitionEnvironment.self) private var env

    @State private var stage: Stage = .pickSource
    @State private var image: UIImage?
    @State private var imageData: Data?
    @State private var description: String = ""
    @State private var pickerItem: PhotosPickerItem?
    @State private var errorMessage: String?
    @State private var showPaywall: Bool = false
    @State private var showCameraPicker = false

    enum Stage: Equatable {
        case pickSource
        case ready
        case analyzing
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
                .sheet(isPresented: $showPaywall) { PaywallSheet() }
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
            Text("Claude will look at the photo and estimate the food name, portion, and macros. You can review and edit before adding.")
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
                        .labelStyle(TitleAndIconLabelStyle())
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
                        .labelStyle(TitleAndIconLabelStyle())
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
        errorMessage = nil
        stage = .pickSource
    }

    private func analyze() async {
        guard let imageData else { return }
        let hint = description.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        stage = .analyzing
        errorMessage = nil
        do {
            let meal = try await env.service.recognize(imageData: imageData, hint: hint)
            // Hand the estimate to the portion sheet — same path as Describe-with-AI — so serving
            // units, gram weights, and the My Foods/staple toolbar all behave identically.
            onEstimated(meal.toSearchResult(userText: hint, source: .photo))
            dismiss()
        } catch FoodRecognitionError.outOfCredits {
            stage = .ready
            showPaywall = true
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            stage = .ready
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
