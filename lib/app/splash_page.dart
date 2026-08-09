import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/theme.dart';

class SplashPage extends StatefulWidget {
  const SplashPage({super.key});

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 850),
    )..forward();
    Timer(const Duration(milliseconds: 1500), () {
      if (mounted) context.go('/reading');
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFF121110),
    body: Stack(
      alignment: Alignment.center,
      children: [
        Container(
          decoration: const BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(0, -.45),
              radius: .9,
              colors: [Color(0xFF302D27), Color(0xFF121110)],
            ),
          ),
        ),
        FadeTransition(
          opacity: CurvedAnimation(parent: _controller, curve: Curves.easeOut),
          child: ScaleTransition(
            scale: Tween(begin: .72, end: 1.0).animate(
              CurvedAnimation(parent: _controller, curve: Curves.easeOutBack),
            ),
            child: const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _Seal(text: '读', size: 92),
                SizedBox(height: 24),
                Text(
                  '耳 读',
                  style: TextStyle(
                    color: Color(0xFFEDE7D8),
                    fontSize: 29,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 8,
                  ),
                ),
                SizedBox(height: 9),
                Text(
                  'READ · LISTEN · STILL',
                  style: TextStyle(
                    color: Color(0xFFB9B0A0),
                    fontSize: 10,
                    letterSpacing: 4,
                  ),
                ),
              ],
            ),
          ),
        ),
        Positioned(
          bottom: 48,
          child: OutlinedButton(
            onPressed: () => context.go('/reading'),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFFEDE7D8),
              side: const BorderSide(color: Colors.white30),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            ),
            child: const Text('以游客身份进入'),
          ),
        ),
      ],
    ),
  );
}

class _Seal extends StatelessWidget {
  const _Seal({required this.text, required this.size});
  final String text;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: const BoxDecoration(
      color: AppColors.seal,
      shape: BoxShape.circle,
    ),
    child: Text(
      text,
      style: TextStyle(
        color: const Color(0xFFFFF2EA),
        fontSize: size * .43,
        fontWeight: FontWeight.w800,
      ),
    ),
  );
}
