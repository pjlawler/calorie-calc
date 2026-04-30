import SwiftUI

/// User-facing usage guide for the app — explains the banking strategy and how to read the
/// Calc / My Plan screens to stay on track for the daily-net-calorie target.
struct InfoView: View {

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    bigIdeaCard
                    section(
                        title: "Banking calories",
                        icon: "tray.and.arrow.down",
                        body:
                        """
                        Your daily *net* goal isn't a hard ceiling — it's an average across the week. Each plan day you eat under your goal puts the unused calories in the bank. Each day you go over draws from it.

                        That's why a single big meal, a few drinks out, or a holiday won't sink your week. You spend Monday–Thursday hitting your plan-day gross goal (say 1,800 kcal eaten + 500 burned = 1,300 net) and bank the difference between 1,300 and your daily-net target of 1,600. Friday or Saturday you can go to 2,500 kcal eaten without exercising and still finish the week on plan.
                        """
                    )
                    section(
                        title: "Plan days vs flex days",
                        icon: "calendar",
                        body:
                        """
                        Set your week split in My Plan → Settings — 5/2 means five plan days, two flex days; 6/1 means six and one. Plan days are when you stay disciplined and bank. Flex days are when you spend.

                        Banking days come at the *start* of your week (per your "Week starts on" setting), flex days at the end. That ordering is intentional — earning the headroom first means flex days are guilt-free.
                        """
                    )
                    section(
                        title: "Reading the Calc tab",
                        icon: "flame.fill",
                        body:
                        """
                        The Calc tab shows the current week with a hero number at the top: the **average daily net** you'd land on if you keep going at today's pace. Stay at or under your daily-net goal and the hero number stays green.

                        Below that the math card breaks down where you are:

                        • **Eaten / Burned / Net** — the running totals for the week so far.
                        • **Variance** — how far ahead or behind your weekly target you are. A positive variance means you've banked extra calories; negative means you're in the red.
                        • **Projected remaining** — what you can still net (eaten minus burned) across the rest of the week and still hit your average-daily-net goal. This is the number to manage by.
                        """
                    )
                    section(
                        title: "Using projected remaining",
                        icon: "chart.line.uptrend.xyaxis",
                        body:
                        """
                        Projected remaining is your spendable budget for the rest of the week, divided across however many days are left. It's the number that tells you whether tonight's pizza is on plan or off plan.

                        Quick mental model:

                        • Big variance built up + plenty of days left → you can ease off and enjoy something out.
                        • Variance is roughly zero → just hit your daily-net goal today and tomorrow.
                        • Variance is negative → either eat tighter for a day or two, or add a workout to claw back. The projected-remaining number updates in real time as you log food and burns, so you can decide on the fly.

                        The point isn't restriction — it's *visibility*. If you can see the cost of a choice before you make it, you stay in control without obsessing.
                        """
                    )
                    section(
                        title: "Logging food",
                        icon: "fork.knife",
                        body:
                        """
                        From the Calc tab, tap any day to open it, then add food to the right meal section. You have four ways in:

                        • **Scan** — scan a barcode (Open Food Facts).
                        • **Photo** — snap a meal and let Claude estimate calories + macros.
                        • **Describe** — type what you ate ("Five Guys cheeseburger") and Claude estimates.
                        • **Search** — query the USDA database by name.

                        Pick a unit (bar, slice, g, oz, cup…) and a quantity. The picker remembers your last choice per food, so the next time you log the same item it pre-fills. Star anything you eat regularly to surface it on the Favorites tab for one-tap logging.
                        """
                    )
                    section(
                        title: "Logging exercise",
                        icon: "figure.run",
                        body:
                        """
                        Workouts come in two flavors:

                        • **Apple Health** — once authorized in Settings, the app pulls your active-energy burn for each day automatically.
                        • **Manual** — add a workout from any day's detail view if Health didn't catch it (gym session without your watch, gardening, etc.).

                        Your daily *workout goal* (set in My Plan → Settings) is the number of calories you aim to burn on plan days. Hitting it is what makes the banking math work — without it, the gross-eaten target eats too much of your weekly budget.
                        """
                    )
                    section(
                        title: "Adjusting your plan",
                        icon: "slider.horizontal.3",
                        body:
                        """
                        Open My Plan → Settings to tune any of:

                        • **Daily net** — your weekly target ÷ 7. Lower it to lose faster, raise it to maintain.
                        • **Plan-day gross** — calories you'll eat on a banking day before exercise.
                        • **Workout goal** — calories you commit to burn on a banking day.
                        • **Week split** — how many banking vs flex days.
                        • **Week starts on** — flex days come at the end of *your* week.

                        Changes apply going forward only. Past weeks keep the goals that were active at the time, so your history stays honest.
                        """
                    )
                    Text("Tap-and-hold any number on the Calc tab to see what it represents. The math is the math — when you trust it, the plan runs itself.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                        .padding(.horizontal, 4)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle("How it works")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    // MARK: - Building blocks

    private var bigIdeaCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(.tint)
                Text("The big idea")
                    .font(.headline)
            }
            Text(
                """
                CalorieCalc treats your daily-net-calorie goal as a *weekly average*, not a hard daily ceiling. Eat under on plan days to bank headroom; spend it on flex days. As long as the week averages out, you're on plan — and a single big meal can't derail you.
                """
            )
            .font(.subheadline)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(LinearGradient(
                    colors: [.accentColor.opacity(0.22), .accentColor.opacity(0.05)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.2), lineWidth: 1)
        )
    }

    private func section(title: String, icon: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(.tint)
                Text(title)
                    .font(.headline)
            }
            Text(LocalizedStringKey(body))
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
        )
    }
}
