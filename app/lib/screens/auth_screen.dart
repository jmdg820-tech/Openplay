import 'package:flutter/material.dart';

import '../services/openplay_api.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../utils/error_messages.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, required this.api, this.onContinueWithoutAccount});

  final OpenPlayApi api;

  /// When provided, offers a way past this screen without signing in --
  /// required for the guest-join flow to be reachable at all: a guest, by
  /// definition, has no OpenPlay account, so they must be able to browse
  /// sessions and use "Join as guest" without ever seeing this form.
  final VoidCallback? onContinueWithoutAccount;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  bool _isSignUp = false;
  bool _busy = false;
  String? _error;

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_isSignUp) {
        await widget.api.signUp(
          email: _emailCtrl.text.trim(),
          password: _passwordCtrl.text,
          displayName: _nameCtrl.text.trim(),
        );
      } else {
        await widget.api.signIn(email: _emailCtrl.text.trim(), password: _passwordCtrl.text);
      }
    } catch (e) {
      setState(() => _error = friendlyAuthError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.xl),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: AppSpacing.xxl),
                  _Wordmark(theme: theme),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    'Find a game. Join in minutes.',
                    style: theme.textTheme.bodyMedium?.copyWith(color: AppColors.slate),
                  ),
                  const SizedBox(height: AppSpacing.xxl),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.xl),
                      child: Form(
                        key: _formKey,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(_isSignUp ? 'Create your account' : 'Welcome back',
                                style: theme.textTheme.headlineSmall),
                            const SizedBox(height: AppSpacing.lg),
                            if (_isSignUp) ...[
                              TextFormField(
                                controller: _nameCtrl,
                                decoration: const InputDecoration(labelText: 'Display name'),
                                validator: (v) =>
                                    (_isSignUp && (v == null || v.trim().isEmpty)) ? 'Required' : null,
                              ),
                              const SizedBox(height: AppSpacing.md),
                            ],
                            TextFormField(
                              controller: _emailCtrl,
                              decoration: const InputDecoration(labelText: 'Email'),
                              keyboardType: TextInputType.emailAddress,
                              validator: (v) =>
                                  (v == null || !v.contains('@')) ? 'Enter a valid email' : null,
                            ),
                            const SizedBox(height: AppSpacing.md),
                            TextFormField(
                              controller: _passwordCtrl,
                              decoration: const InputDecoration(labelText: 'Password'),
                              obscureText: true,
                              validator: (v) => (v == null || v.length < 6) ? 'Min 6 characters' : null,
                              onFieldSubmitted: (_) => _submit(),
                            ),
                            if (_error != null) ...[
                              const SizedBox(height: AppSpacing.md),
                              Container(
                                padding: const EdgeInsets.all(AppSpacing.md),
                                decoration: BoxDecoration(
                                  color: AppColors.errorBg,
                                  borderRadius: BorderRadius.circular(AppRadius.md),
                                ),
                                child: Row(
                                  children: [
                                    const Icon(Icons.error_outline_rounded, size: 18, color: AppColors.error),
                                    const SizedBox(width: AppSpacing.sm),
                                    Expanded(
                                      child: Text(_error!,
                                          style: theme.textTheme.bodySmall?.copyWith(color: AppColors.error)),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                            const SizedBox(height: AppSpacing.lg),
                            FilledButton(
                              onPressed: _busy ? null : _submit,
                              child: _busy
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.white))
                                  : Text(_isSignUp ? 'Sign up' : 'Sign in'),
                            ),
                            const SizedBox(height: AppSpacing.xs),
                            Center(
                              child: TextButton(
                                onPressed: () => setState(() => _isSignUp = !_isSignUp),
                                child: Text(_isSignUp
                                    ? 'Already have an account? Sign in'
                                    : "Don't have an account? Sign up"),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (widget.onContinueWithoutAccount != null) ...[
                    const SizedBox(height: AppSpacing.lg),
                    TextButton.icon(
                      onPressed: widget.onContinueWithoutAccount,
                      icon: const Icon(Icons.explore_outlined, size: 18),
                      label: const Text('Browse sessions without an account'),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.xl),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Wordmark extends StatelessWidget {
  const _Wordmark({required this.theme});
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return RichText(
      text: TextSpan(
        style: theme.textTheme.displaySmall,
        children: const [
          TextSpan(text: 'Open'),
          TextSpan(text: 'Play', style: TextStyle(color: AppColors.courtTeal)),
        ],
      ),
    );
  }
}
