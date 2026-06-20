import 'package:flutter/material.dart';

const _bg = Color(0xFF0B0D16);
const _bg2 = Color(0xFF11141F);
const _neonCyan = Color(0xFF36E3E3);
const _lineColor = Color(0xFF313A55);

class GameView extends StatelessWidget {
  const GameView({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg2,
        elevation: 0,
        centerTitle: true,
        title: const Text(
          'V I B E C O D E',
          style: TextStyle(
            color: _neonCyan,
            letterSpacing: 6,
            fontWeight: FontWeight.w700,
            fontSize: 13,
          ),
        ),
      ),
      body: Stack(
        children: [
          Positioned.fill(child: CustomPaint(painter: _BgPainter())),
          Center(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final side = constraints.maxWidth < constraints.maxHeight
                    ? constraints.maxWidth * 0.72
                    : constraints.maxHeight * 0.72;
                return CustomPaint(
                  size: Size(side, side),
                  painter: _RingPainter(),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _BgPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(0.9, -0.9),
          radius: 1.4,
          colors: [const Color(0xFF36E3E3).withAlpha(20), Colors.transparent],
        ).createShader(Rect.fromLTWH(0, 0, size.width, size.height)),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _RingPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 4;

    // Outer glow
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 28
        ..color = _neonCyan.withAlpha(25)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18),
    );

    // Mid glow
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 8
        ..color = _neonCyan.withAlpha(80)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );

    // Main ring
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = _neonCyan,
    );

    // Inner guide ring
    canvas.drawCircle(
      center,
      radius * 0.82,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = _lineColor,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
