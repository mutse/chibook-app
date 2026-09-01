import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_state.dart';
import '../../core/adaptive.dart';
import '../../core/theme.dart';

class ZLibraryAccountPage extends ConsumerStatefulWidget {
  const ZLibraryAccountPage({super.key});

  @override
  ConsumerState<ZLibraryAccountPage> createState() =>
      _ZLibraryAccountPageState();
}

class _ZLibraryAccountPageState extends ConsumerState<ZLibraryAccountPage> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _submitting = false;
  bool _obscurePassword = true;
  String? _error;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(
      appControllerProvider.select((state) => state.zLibraryAccount),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Z-Library')),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: maxReadingColumnWidth),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 36),
            children: [
              if (account == null)
                _buildLoginCard(context)
              else
                _buildAccountCard(context),
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
                        '登录后可在书架搜索页切换到 Z-Library，检索并下载 TXT、EPUB 或 PDF。'
                        '下载完成后文件会进入应用私有书库，并沿用现有阅读、划线与听书能力。',
                        style: TextStyle(height: 1.65),
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        '密码只用于本次登录，不会保存；会话凭证保存在系统安全存储中。'
                        '请仅下载公版、开放授权或你已合法取得使用权的内容。'
                        'Z-Library 没有稳定的公开 API，服务端调整可能导致此功能暂时不可用。',
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

  Widget _buildLoginCard(BuildContext context) => Card(
    elevation: 0,
    child: Padding(
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(
            Icons.cloud_download_outlined,
            size: 48,
            color: AppColors.bamboo,
          ),
          const SizedBox(height: 12),
          Text(
            '登录 Z-Library',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 18),
          TextField(
            controller: _emailController,
            enabled: !_submitting,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.username, AutofillHints.email],
            decoration: const InputDecoration(
              labelText: '邮箱',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _passwordController,
            enabled: !_submitting,
            obscureText: _obscurePassword,
            textInputAction: TextInputAction.done,
            autofillHints: const [AutofillHints.password],
            onSubmitted: (_) => _login(),
            decoration: InputDecoration(
              labelText: '密码',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: _obscurePassword ? '显示密码' : '隐藏密码',
                onPressed: () =>
                    setState(() => _obscurePassword = !_obscurePassword),
                icon: Icon(
                  _obscurePassword
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
              ),
            ),
          ),
          if (_error case final message?) ...[
            const SizedBox(height: 12),
            Text(message, style: const TextStyle(color: AppColors.seal)),
          ],
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: _submitting ? null : _login,
            icon: _submitting
                ? const SizedBox(
                    width: 17,
                    height: 17,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.login),
            label: Text(_submitting ? '登录中…' : '登录'),
          ),
        ],
      ),
    ),
  );

  Widget _buildAccountCard(BuildContext context) {
    final account = ref.read(appControllerProvider).zLibraryAccount!;
    return Card(
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          children: [
            const CircleAvatar(
              radius: 34,
              backgroundColor: AppColors.bambooSoft,
              child: Icon(Icons.cloud_done, size: 30, color: AppColors.bamboo),
            ),
            const SizedBox(height: 12),
            Text(
              account.name.isEmpty ? account.email : account.name,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
            if (account.email.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(
                account.email,
                style: const TextStyle(color: AppColors.graphite),
              ),
            ],
            const SizedBox(height: 18),
            OutlinedButton.icon(
              onPressed: _submitting ? null : _logout,
              icon: const Icon(Icons.logout),
              label: const Text('退出登录'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _login() async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await ref
          .read(appControllerProvider.notifier)
          .loginZLibrary(
            email: _emailController.text,
            password: _passwordController.text,
          );
      _passwordController.clear();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Z-Library 已登录')));
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('退出 Z-Library？'),
        content: const Text('本机会话凭证将被清除，已下载到书架的电子书不会受影响。'),
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
    setState(() => _submitting = true);
    try {
      await ref.read(appControllerProvider.notifier).logoutZLibrary();
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }
}
