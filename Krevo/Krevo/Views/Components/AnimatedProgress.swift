import SwiftUI

struct AnimatedProgress: View {
    let progress: Double
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(Color.krevoBorder)

                RoundedRectangle(cornerRadius: height / 2)
                    .fill(
                        LinearGradient(
                            colors: [.krevoViolet, .krevoFuchsia],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(0, geo.size.width * min(progress, 1.0)))
            }
        }
        .frame(height: height)
        .animation(.linear(duration: 0.1), value: progress)
    }
}

// MARK: - Indeterminate Variant

struct IndeterminateProgress: View {
    var height: CGFloat = 4
    @State private var offset: CGFloat = -1.0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(Color.krevoBorder)

                RoundedRectangle(cornerRadius: height / 2)
                    .fill(
                        LinearGradient(
                            colors: [.krevoViolet, .krevoFuchsia],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geo.size.width * 0.3)
                    .offset(x: offset * geo.size.width)
            }
            .clipShape(RoundedRectangle(cornerRadius: height / 2))
        }
        .frame(height: height)
        .onAppear {
            withAnimation(
                .easeInOut(duration: 1.2)
                .repeatForever(autoreverses: true)
            ) {
                offset = 0.7
            }
        }
    }
}
