import 'package:coconut_design_system/coconut_design_system.dart' hide CoconutTextField, CoconutToast;
import 'package:coconut_wallet/app/router/app_route_names.dart';
import 'package:coconut_wallet/design_system/context/coconut_theme_context_extension.dart';
import 'package:coconut_wallet/localization/strings.g.dart';
import 'package:coconut_wallet/providers/ark_provider.dart';
import 'package:coconut_wallet/screens/ark/ark_unlock_flow.dart';
import 'package:coconut_wallet/ui/coconut/coconut_overlays.dart';
import 'package:coconut_wallet/ui/coconut/coconut_text_field.dart';
import 'package:coconut_wallet/utils/logger.dart';
import 'package:coconut_wallet/widgets/common/buttons/fixed_bottom_button.dart';
import 'package:coconut_wallet/widgets/common/overlays/common_bottom_sheets.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// Imports a VTXO this wallet exported (the VTXO detail's hidden export), from the VTXO
/// overview's menu. bark only accepts VTXOs whose keys come from this wallet's seed.
Future<void> showVtxoImportSheet(BuildContext context, int walletId) async {
  if (!await openArkWalletForSession(context, walletId, userInitiated: true) || !context.mounted) return;
  final imported = await CommonBottomSheets.showBottomSheet<bool>(
    context: context,
    title: t.ark.vtxo.import_title,
    screenName: '${AppRouteNames.arkWallet}/import',
    showCloseButton: true,
    child: _VtxoImportSheet(walletId: walletId),
  );
  if (imported == true && context.mounted) {
    CoconutToast.showBottomToast(context: context, text: t.ark.vtxo.imported);
  }
}

class _VtxoImportSheet extends StatefulWidget {
  const _VtxoImportSheet({required this.walletId});

  final int walletId;

  @override
  State<_VtxoImportSheet> createState() => _VtxoImportSheetState();
}

class _VtxoImportSheetState extends State<_VtxoImportSheet> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  bool _isImporting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() => _error = null));
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _import() async {
    final encoded = _controller.text.trim();
    if (encoded.isEmpty) return;
    setState(() => _isImporting = true);
    try {
      await context.read<ArkProvider>().importVtxo(widget.walletId, encoded);
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      Logger.error('VtxoImportSheet: import failed: $error');
      if (mounted) setState(() => _error = '${t.ark.vtxo.import_failed}: $error');
    } finally {
      if (mounted) setState(() => _isImporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.coconutColors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(t.ark.vtxo.import_description, style: CoconutTypography.body3_12.setColor(colors.secondaryText)),
          CoconutLayout.spacing_400h,
          CoconutTextField(
            controller: _controller,
            focusNode: _focusNode,
            onChanged: (_) {},
            maxLines: 4,
            backgroundColor: colors.background,
            placeholderText: t.ark.vtxo.import_placeholder,
            autocorrect: false,
            enableSuggestions: false,
            textInputType: TextInputType.visiblePassword,
            clearButtonVisibility: CoconutTextFieldClearButtonVisibility.whenNotEmpty,
            onClear: _controller.clear,
            isError: _error != null,
          ),
          if (_error != null) ...[
            CoconutLayout.spacing_200h,
            Text(_error!, style: CoconutTypography.body3_12.setColor(colors.danger)),
          ],
          CoconutLayout.spacing_500h,
          InlineActionButton(
            text: _isImporting ? t.ark.vtxo.importing : t.ark.vtxo.import_button,
            isActive: !_isImporting && _controller.text.trim().isNotEmpty,
            onPressed: _import,
          ),
        ],
      ),
    );
  }
}
