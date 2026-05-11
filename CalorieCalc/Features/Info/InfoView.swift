import SwiftUI

/// First-person walkthrough — how the banking strategy works, why I built CalorieCalc to track
/// it, and how to read the two numbers that drive every decision (Eat Today + Projected
/// Remaining).
struct InfoView: View {

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Color.clear.frame(height: 0).id("top")
                    bigIdeaCard

                    section(
                        title: "Why I built this",
                        icon: "sparkles",
                        body:
                        """
                        I'm Patrick. I built CalorieCalc for myself.

                        For years I tried to lose weight without giving up the things that make life worth living — dinners with friends, a beer on Friday, a real dessert now and then. Every "track your daily calories" app failed me the same way: life isn't a flat line. One steakhouse meal would put me over for the day, and the app would treat that as failure.

                        Eventually I stopped thinking in days and started thinking in weeks. If my target was 1,600 net calories per day, that's 11,200 across the week. I could spend that however I wanted, as long as the average came out right.

                        Most days I'd eat lighter and exercise. Those calories went into a "bank." Then on Friday or Saturday I'd cash some of that in for a dinner out and not torpedo my progress, because I was spending what I'd already saved.

                        It worked. The problem was tracking it. Every app I tried showed me one day at a time and made me do the rest of the math in my head — adding up what I'd eaten so far this week, subtracting workouts, projecting out to Sunday — just to know if tonight's pizza was on plan.

                        So I built this.
                        """
                    )

                    section(
                        title: "Eat Today",
                        icon: "fork.knife",
                        body:
                        """
                        The hero number on the Calc tab. **How many more calories I can eat right now and still be on plan.**

                        It updates live. When I log a meal it goes down. When I log a workout it goes up. It's a real-time snapshot of where I stand against the cumulative plan through this point in the week — under-eating earlier in the week pads it; over-eating drains it.

                        It does *not* assume anything about the rest of today. If I haven't done my workout yet, it doesn't pre-credit those calories — the moment I log the burn, the number jumps. That keeps it honest about what's actually banked vs. what I'm planning.

                        Practical use:

                        • Big positive number → cruise. Eat normal, hit your targets.
                        • Near zero → just stay on today's bank-day plan and keep moving.
                        • Negative → tighten up for a meal or two, or get a workout in. The number updates immediately so you can decide on the fly.
                        """
                    )

                    section(
                        title: "Projected Remaining",
                        icon: "chart.line.uptrend.xyaxis",
                        body:
                        """
                        The forward-looking number. **What's left in your weekly budget after you finish out the week at today's pace.**

                        Where Eat Today is "how I'm doing right now," Projected Remaining is "how the week is going to land." It folds in your remaining workout commitments and what's left of the weekly target.

                        Practical use:

                        • Healthy positive → on track for the week. The bank is filling.
                        • Shrinking but still positive → you're spending the bank — fine if you've got bonus days coming up.
                        • Going negative → the week is heading off-plan. Add a workout, dial back tomorrow's gross, or accept it and reset Sunday.
                        """
                    )

                    section(
                        title: "Bank days vs bonus days",
                        icon: "calendar",
                        body:
                        """
                        Settings → Week split lets you set something like "5/2" — five bank days at the start of the week, two bonus days at the end.

                        Bank days have a tighter target — eat your bank-day gross, hit your workout goal, build up calories. Bonus days have a higher target — that's where you spend what you saved.

                        I want to be clear: every day is flexible. There's no day where the app stops you from eating more. The split just tells the math what to *target* for each day, so the daily-net average works out across the week. I order bank days first because earning the headroom before spending it makes bonus days actually feel like a reward instead of a guilt trip.
                        """
                    )

                    section(
                        title: "Logging",
                        icon: "plus.circle",
                        body:
                        """
                        From the Calc tab, tap any day to open it, then add food to the right meal section. Four ways in:

                        • **Scan** — barcode lookup via Open Food Facts.
                        • **Photo** — Claude estimates calories + macros from a picture.
                        • **Describe** — type "Five Guys cheeseburger" and Claude does the math.
                        • **Search** — USDA database by name.

                        Pick a unit (bar, slice, g, oz, cup…) and an amount. The picker remembers your last choice per food, so the next time you log it, it pre-fills.

                        For exercise, Apple Health pulls active-energy automatically once you authorize it in Settings. Add manual workouts for anything Health misses — gym session without the watch, gardening, etc.

                        Tap the bolt on anything you eat regularly to add it to Quick Add — it surfaces for one-tap re-logging from the Calc tab.
                        """
                    )

                    section(
                        title: "Tuning the plan",
                        icon: "slider.horizontal.3",
                        body:
                        """
                        My Plan → Settings is where the targets live:

                        • **Daily net** — your weekly goal ÷ 7. Lower it to lose faster, raise it to maintain.
                        • **Daily gross (bank days)** — calories eaten before exercise on a banking day.
                        • **Workout goal** — calories you commit to burn on a banking day. Hitting this is what makes the math work — without it, the gross-eaten target eats too much of the weekly budget.
                        • **Week split** — how many bank vs bonus days.
                        • **Week starts on** — bonus days come at the end of *your* week.

                        Changes apply going forward only. Past weeks keep the goals that were active at the time, so the history stays honest about what you were aiming for then.
                        """
                    )

                    Text("That's the whole system. The math runs the plan; you just decide.")
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
            .onReceive(NotificationCenter.default.publisher(for: .scrollToTop)) { _ in
                withAnimation { proxy.scrollTo("top", anchor: .top) }
            }
            }
        }
    }

    // MARK: - Building blocks

    private var bigIdeaCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "tray.and.arrow.down").foregroundStyle(.tint)
                Text("Bank, then spend")
                    .font(.headline)
            }
            Text(
                """
                Your daily-net-calorie goal is a *weekly average*, not a daily ceiling. Eat under earlier in the week to bank calories; spend them on a bigger day later. As long as the week averages out, you're on plan — and a single big meal can't derail you.
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
