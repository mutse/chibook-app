import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../app/app_state.dart';
import '../../core/adaptive.dart';
import '../../core/theme.dart';
import '../../services/weread_service.dart';

class WeReadAccountPage extends ConsumerStatefulWidget {
  const WeReadAccountPage({super.key});

  @override
  ConsumerState<WeReadAccountPage> createState() => _WeReadAccountPageState();
}

class _WeReadAccountPageState extends ConsumerState<WeReadAccountPage> {
  WeReadLoginSession? _session;
  String? _error;
  bool _starting = false;
  bool _needsOtp = false;
  bool _submittingOtp = false;
  final _otpController = TextEditingController();
  int _operation = 0;

  @override
  void dispose() {
    _operation++;
    _otpController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(appControllerProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('微信读书')),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: maxReadingColumnWidth),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 36),
            children: [
              if (state.weReadAccount case final account?)
                _LoggedInCard(
                  account: account,
                  syncing: state.isWeReadSyncing,
                  onSync: _sync,
                  onLogout: _logout,
                )
              else
                _LoginCard(
                  session: _session,
                  starting: _starting,
                  needsOtp: _needsOtp,
                  submittingOtp: _submittingOtp,
                  otpController: _otpController,
                  error: _error,
                  onStart: _beginLogin,
                  onSubmitOtp: _submitOtp,
                ),
              const SizedBox(height: 18),
              Card(
                elevation: 0,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '使用说明',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        '登录后可同步微信读书书架，并在本应用内按章节阅读有权限访问的电子书。'
                        '登录 Cookie 只保存在系统安全存储中，不会写入普通偏好设置。',
                        style: TextStyle(height: 1.65),
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        '该功能使用微信读书网页端兼容接口，并非面向第三方的正式开放 API；'
                        '接口调整、会员状态或图书版权限制都可能导致个别书籍暂时无法读取。',
                        style: TextStyle(
                          height: 1.65,
                          color: AppColors.graphite,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _beginLogin() async {
    final operation = ++_operation;
    setState(() {
      _starting = true;
      _needsOtp = false;
      _submittingOtp = false;
      _otpController.clear();
      _session = null;
      _error = null;
    });
    try {
      final controller = ref.read(appControllerProvider.notifier);
      final session = await controller.startWeReadLogin();
      if (!mounted || operation != _operation) return;
      setState(() {
        _session = session;
        _starting = false;
      });
      await _completeLogin(session, operation: operation);
    } catch (error) {
      if (!mounted || operation != _operation) return;
      setState(() {
        _starting = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _submitOtp() async {
    final session = _session;
    if (session == null) return;
    final otp = _otpController.text.trim();
    if (!RegExp(r'^\d{4}$').hasMatch(otp)) {
      setState(() => _error = '请输入四位数字验证码');
      return;
    }
    setState(() {
      _submittingOtp = true;
      _error = null;
    });
    await _completeLogin(session, operation: _operation, otp: otp);
  }

  Future<void> _completeLogin(
    WeReadLoginSession session, {
    required int operation,
    String otp = '',
  }) async {
    try {
      await ref
          .read(appControllerProvider.notifier)
          .completeWeReadLogin(session, otp: otp);
      if (!mounted || operation != _operation) return;
      setState(() {
        _needsOtp = false;
        _submittingOtp = false;
        _error = null;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('微信读书已登录，书架同步完成')));
    } on WeReadOtpRequiredException {
      if (!mounted || operation != _operation) return;
      setState(() {
        _needsOtp = true;
        _submittingOtp = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted || operation != _operation) return;
      setState(() {
        _starting = false;
        _submittingOtp = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _sync() async {
    try {
      await ref.read(appControllerProvider.notifier).syncWeReadShelf();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('微信读书书架已同步')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('退出微信读书？'),
        content: const Text('登录凭证和已同步的微信读书书籍将从本机移除，本地导入书籍不会受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('退出登录'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(appControllerProvider.notifier).logoutWeRead();
  }
}

class _LoginCard extends StatelessWidget {
  const _LoginCard({
    required this.session,
    required this.starting,
    required this.needsOtp,
    required this.submittingOtp,
    required this.otpController,
    required this.error,
    required this.onStart,
    required this.onSubmitOtp,
  });

  final WeReadLoginSession? session;
  final bool starting;
  final bool needsOtp;
  final bool submittingOtp;
  final TextEditingController otpController;
  final String? error;
  final VoidCallback onStart;
  final VoidCallback onSubmitOtp;

  @override
  Widget build(BuildContext context) => Card(
    elevation: 0,
    child: Padding(
      padding: const EdgeInsets.all(22),
      child: Column(
        children: [
          const Icon(Icons.auto_stories, size: 48, color: AppColors.bamboo),
          const SizedBox(height: 12),
          Text(
            session == null ? '登录微信读书' : (needsOtp ? '输入登录验证码' : '使用微信扫描二维码'),
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(
            session == null
                ? '同步你的书架与阅读进度'
                : (needsOtp
                      ? '微信需要二次验证，请输入手机上显示的四位验证码'
                      : '在微信中确认登录后，此页面会自动完成同步'),
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.graphite),
          ),
          if (session case final value?) ...[
            const SizedBox(height: 18),
            Semantics(
              label: '微信读书登录二维码',
              child: Container(
                color: Colors.white,
                padding: const EdgeInsets.all(12),
                child: QrImageView(
                  data: value.confirmUrl,
                  size: 220,
                  eyeStyle: const QrEyeStyle(color: Colors.black),
                  dataModuleStyle: const QrDataModuleStyle(color: Colors.black),
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (needsOtp) ...[
              SizedBox(
                width: 220,
                child: TextField(
                  controller: otpController,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.done,
                  maxLength: 4,
                  textAlign: TextAlign.center,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    counterText: '',
                    hintText: '四位验证码',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => onSubmitOtp(),
                ),
              ),
              const SizedBox(height: 10),
              FilledButton(
                onPressed: submittingOtp ? null : onSubmitOtp,
                child: submittingOtp
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('确认验证码'),
              ),
            ] else
              const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 9),
                  Text('等待扫码确认…'),
                ],
              ),
          ],
          if (error case final message?) ...[
            const SizedBox(height: 14),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.seal),
            ),
          ],
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: starting || submittingOtp ? null : onStart,
            icon: starting
                ? const SizedBox(
                    width: 17,
                    height: 17,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.qr_code_2),
            label: Text(session == null ? '生成登录二维码' : '重新生成二维码'),
          ),
        ],
      ),
    ),
  );
}

class _LoggedInCard extends StatelessWidget {
  const _LoggedInCard({
    required this.account,
    required this.syncing,
    required this.onSync,
    required this.onLogout,
  });

  final WeReadAccount account;
  final bool syncing;
  final VoidCallback onSync;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) => Card(
    elevation: 0,
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          CircleAvatar(
            radius: 34,
            backgroundColor: AppColors.bambooSoft,
            backgroundImage: account.avatarUrl == null
                ? null
                : NetworkImage(account.avatarUrl!),
            child: account.avatarUrl == null
                ? Text(
                    account.name.isEmpty ? '微' : account.name.substring(0, 1),
                    style: const TextStyle(
                      fontSize: 24,
                      color: AppColors.bamboo,
                    ),
                  )
                : null,
          ),
          const SizedBox(height: 12),
          Text(
            account.name,
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 3),
          const Text('微信读书已连接', style: TextStyle(color: AppColors.bamboo)),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: syncing ? null : onSync,
                  icon: syncing
                      ? const SizedBox(
                          width: 17,
                          height: 17,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.sync),
                  label: Text(syncing ? '同步中' : '同步书架'),
                ),
              ),
              const SizedBox(width: 10),
              OutlinedButton(onPressed: onLogout, child: const Text('退出')),
            ],
          ),
        ],
      ),
    ),
  );
}
