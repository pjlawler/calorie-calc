import SwiftUI

/// First-person walkthrough — the banking strategy, why I built this, the numbers that worked
/// for me, and how every tab fits together.
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
                        I'm Patrick. I built this for myself.

                        Every big weight-loss app tries to work for everyone — keto, low sugar, body building, macros, fasting windows. I didn't need a system for somebody else's goals. I just wanted to track how many calories I ate, how many I burned, and the difference — and have it average out across the week so a Friday dinner didn't have to feel like a failure.

                        Using this exact approach I lost more than 60 lbs in under 6 months. Twice.

                        The first time I hit my goal, I stopped tracking — and slowly gained it all back. The second time I learned what I'd missed: at goal weight you don't *quit*, you just adjust. If the trend line creeps up, nudge the net down by 50–100 and watch it for a couple of weeks. That's maintenance.

                        I made this so the math runs itself and the strategy is the same whether I'm losing or holding.
                        """
                    )

                    section(
                        title: "The plan, with real numbers",
                        icon: "number",
                        body:
                        """
                        Your numbers will be different, but the shape is the same. Here's what worked for me.

                        **Losing fast.** Daily-net goal of **1,150 kcal**, planned workout burn of **350 kcal**. That gives me a 1,500-kcal eating *average*. Instead I ate 1,300 most days and banked the rest. That earned me one bonus day a week around **2,700 kcal** — a real dinner out, no guilt — and I still dropped about **2.5 lbs/week**.

                        **Closing in on goal.** Raised the net to **1,450** (still 350 burn). Same banking pattern gave me **~2,550 kcal** on the last two days. Down about **1 lb/week** with a much friendlier rhythm.

                        **Maintaining.** Bumped the net to **1,700**. Bonus days come in around **2,675 kcal**. Same banking, different setpoint. When the trend drifts up I drop the net slightly and let it stabilize.

                        The Calc tab does this math live, all day, every day.
                        """
                    )

                    section(
                        title: "Reading the Calc tab",
                        icon: "flame",
                        body:
                        """
                        The Calc tab shows the current week, one row per day. For each day you'll see calories **consumed** and **burned**. For today (and any prior day) you'll see **Remaining** — what's left in today's budget given how the rest of the week is going.

                        If you went over yesterday it pulls from today. If you ate light, today's remaining grows. The number always reflects your *current* variance across the week, not where you started this morning.

                        Two headline numbers sit above the days:

                        • **Eat Today** — how many more calories you can eat *right now* and still be on plan. Drops when you log food, rises when you log a workout. It does *not* pre-credit a workout you haven't done.

                        • **Projected Remaining** — where the week will land if today's pace continues. Eat Today says "right now"; Projected Remaining says "how Sunday looks from here."

                        If you're over on the last day of the week, it's not the end of the world. Reset Sunday and go again.
                        """
                    )

                    section(
                        title: "Bank days vs bonus days",
                        icon: "calendar",
                        body:
                        """
                        Settings → Week split lets you pick something like **5/2** — five bank days, two bonus days.

                        Bank days have the tighter eating target. Hit your bank-day gross, burn the planned workout, build the cushion. Bonus days have a higher target — that's where you spend what you saved.

                        The split is just what the math *targets* per day — the app never stops you from eating. I order bank days first because earning the headroom before spending it is what makes a bonus day feel like a reward instead of a guilt trip.
                        """
                    )

                    section(
                        title: "Quick Add",
                        icon: "bolt.fill",
                        body:
                        """
                        Quick Add is the fast lane. From the Calc tab, tap Quick Add and you'll see:

                        • **Quick items** — anything from My Foods that you marked with the ⚡ bolt. Use it for things you eat the same way every time — a protein bar, your usual coffee, a daily shake.
                        • **Manual entry** — type a name, calories, and macros for one-off things you'd never bother saving.

                        One tap to log; no searching required.
                        """
                    )

                    section(
                        title: "Daily log",
                        icon: "list.bullet.clipboard",
                        body:
                        """
                        Tap any day on the Calc tab to open its daily log. Food is grouped by meal — Breakfast, Lunch, Dinner, Snacks — with calorie and macro totals shown on each meal header. Workouts (Apple Health + anything manual) sit below. At the bottom, a **Summary** shows exactly how that day's Remaining was calculated, including planned vs actual exercise so you can see *why* the number says what it says.

                        Sections start collapsed for a clean view. Logging an item live expands its section automatically.
                        """
                    )

                    section(
                        title: "Logging anything",
                        icon: "plus.circle",
                        body:
                        """
                        The Log button on the daily log opens a sheet with two areas:

                        • **My Foods + Recents** — pick from your saved list or things you've logged before. One tap, done.
                        • **Search tab** — four ways to find anything else:
                          • **Scan** a barcode (Open Food Facts).
                          • **Photo** — Claude estimates calories + macros from a picture.
                          • **Describe** — type "Five Guys cheeseburger" and Claude does the math.
                          • **Manual entry** — type the numbers yourself when you already know them.

                        The meal selector at the top of the sheet decides where the item lands. The search bar at the bottom hunts across your foods, your recents, and the USDA national food database in one place.

                        For exercise, Apple Health pulls active-energy automatically once you authorize it. Add manual workouts for anything Health misses — gym session without the watch, gardening, whatever.
                        """
                    )

                    section(
                        title: "Progress",
                        icon: "chart.line.uptrend.xyaxis",
                        body:
                        """
                        Progress is the look-back. Pick a range — 7, 14, 30, 60, 90, 180 days, a year, or a custom window — and you'll see your weight chart, current-weight summary, and the history rows for every metric (net calories, calories, macros, exercise, steps) averaged over the period.

                        The weight chart includes a **trend line** — a regression fit through every weigh-in. Day-to-day weight bounces ±2 lbs on water alone, which makes it hard to tell if the plan is actually working. The trend line filters that noise so you can see the real slope and decide whether to tweak the plan.

                        This is where maintenance happens. Trend creeping up? Drop the net a little, give it two weeks, look again.
                        """
                    )

                    section(
                        title: "My Foods",
                        icon: "fork.knife",
                        body:
                        """
                        Save the things you eat regularly so you stop re-searching them every week.

                        • Tap the ⚡ bolt on any food to mark it as **Quick Add**. Those surface for one-tap logging from the Calc tab.
                        • Add **tags** to organize your list — make whatever categories work for you (Breakfast, Prep, Snacks, Treats) and assign them to your saved items.
                        • Filter the list by tag from the My Foods toolbar.
                        """
                    )

                    section(
                        title: "Tuning the plan",
                        icon: "slider.horizontal.3",
                        body:
                        """
                        Settings is where the targets live:

                        • **Daily net** — your weekly goal ÷ 7. Lower to lose faster, raise to maintain.
                        • **Daily gross (bank days)** — calories eaten before exercise on a banking day.
                        • **Workout goal** — what you commit to burn on a banking day. Without it, the eating target eats too much of the weekly budget.
                        • **Week split** — how many bank vs bonus days.
                        • **Week starts on** — so bonus days land at the end of *your* week.

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
