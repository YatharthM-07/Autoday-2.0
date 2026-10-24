//
//  MonthPickerView.swift
//  AutoDay 2.0
//
//  Created by Archita Saxena on 21/10/26.
//
//  Month picker in the nav bar.

import SwiftUI

// MARK: - Month Picker Sheet

struct MonthPickerView: View {
    @Binding var pickerMonth: Date
    let onConfirm: () -> Void

    private static let monthNames: [String] = {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMMM"
        return (1...12).map { m -> String in
            var c = DateComponents(); c.month = m; c.year = 2026
            return fmt.string(from: Calendar.current.date(from: c)!)
        }
    }()

    @State private var selMonth: Int
    @State private var selYear: Int

    init(pickerMonth: Binding<Date>, onConfirm: @escaping () -> Void) {
        _pickerMonth = pickerMonth
        self.onConfirm = onConfirm
        let cal = Calendar.current
        _selMonth = State(initialValue: cal.component(.month, from: pickerMonth.wrappedValue))
        _selYear  = State(initialValue: cal.component(.year,  from: pickerMonth.wrappedValue))
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Select Month")
                .font(.system(size: 18, weight: .bold))
                .padding(.top, 20)

            HStack {
                Picker("Month", selection: $selMonth) {
                    ForEach(1...12, id: \.self) { m in
                        Text(Self.monthNames[m - 1]).tag(m)
                    }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)

                Picker("Year", selection: $selYear) {
                    ForEach(2024...2030, id: \.self) { y in
                        Text(String(y)).tag(y)
                    }
                }
                .pickerStyle(.wheel)
                .frame(width: 110)
            }
            .padding(.horizontal, 16)

            Button("Go to Month") {
                var comps = DateComponents()
                comps.year = selYear; comps.month = selMonth; comps.day = 1
                if let d = Calendar.current.date(from: comps) { pickerMonth = d }
                onConfirm()
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color(hex: "#7C5CD6"), in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
    }
}
