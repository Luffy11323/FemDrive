import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'app_utils.dart';

class RideStatusChart extends StatelessWidget {
  const RideStatusChart({super.key});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, int>>(
      future: AdminService.getRideStatusCounts(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Center(child: Text('Error loading chart data'));
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final counts = snapshot.data!;
        final total = counts.values.fold(0, (sum, value) => sum + value);
        if (total == 0) return const Center(child: Text('No ride data available'));

        return PieChart(
          PieChartData(
            sections: RideStatus.values
                .asMap()
                .entries
                .where((entry) => counts[entry.value]! > 0)
                .map((entry) {
                  final index = entry.key;
                  final status = entry.value;
                  final value = counts[status]!.toDouble();
                  return PieChartSectionData(
                    color: Colors.primaries[index % Colors.primaries.length],
                    value: value,
                    title: '${(value / total * 100).toStringAsFixed(1)}%',
                    radius: 50,
                    titleStyle: const TextStyle(fontSize: 12, color: Colors.white),
                  );
                }).toList(),
            sectionsSpace: 2,
            centerSpaceRadius: 40,
          ),
        );
      },
    );
  }
}