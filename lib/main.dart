import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart'; // 👈 import

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: ".env"); // 👈 carga .env

  await Supabase.initialize(
    url: dotenv.env['SUPABASE_URL']!,
    anonKey: dotenv.env['SUPABASE_ANON_KEY']!,
  );

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Registro de comensales',
      theme: ThemeData(useMaterial3: true),
      home: const ComensalesPage(),
    );
  }
}

class PersonalLite {
  final String nombres;
  final String apPat;
  final String apMat;

  PersonalLite({
    required this.nombres,
    required this.apPat,
    required this.apMat,
  });

  factory PersonalLite.fromJson(Map<String, dynamic> j) => PersonalLite(
    nombres: j['nombres'] as String,
    apPat: j['apellido_paterno'] as String,
    apMat: j['apellido_materno'] as String,
  );

  String get nombreCompleto => '$nombres $apPat $apMat';
}

class Comensal {
  final String idComensal; // PK
  final String fecha;      // YYYY-MM-DD
  final String hora;       // HH:mm:ss
  final String? comida;    // GENERATED ALWAYS
  final String fkPersonal; // DNI
  final PersonalLite? personal;

  Comensal({
    required this.idComensal,
    required this.fecha,
    required this.hora,
    required this.fkPersonal,
    this.comida,
    this.personal,
  });

  factory Comensal.fromJson(Map<String, dynamic> j) => Comensal(
    idComensal: j['id_comensal'] as String,
    fecha: j['fecha'] as String,
    hora: j['hora'] as String,
    comida: j['comida'] as String?,
    fkPersonal: j['fk_personal'] as String,
    personal: j['personal'] == null
        ? null
        : PersonalLite.fromJson(j['personal'] as Map<String, dynamic>),
  );

  String get nombreCompleto => personal?.nombreCompleto ?? '(sin nombre)';
}

enum _AppMenuOption { comensales, personal }

class ComensalesPage extends StatefulWidget {
  const ComensalesPage({super.key});
  @override
  State<ComensalesPage> createState() => _ComensalesPageState();
}

class _ComensalesPageState extends State<ComensalesPage> {
  final _client = Supabase.instance.client;
  final List<Comensal> _items = [];
  bool _loading = true;
  String? _error;
  RealtimeChannel? _channel;

  @override
  void initState() {
    super.initState();
    _fetchAll();
    _setupRealtime();
  }

  Future<List<Comensal>> _selectAllJoined() async {
    final data = await _client
        .from('comensales')
        .select(
      'id_comensal, fecha, hora, comida, fk_personal, '
          'personal:fk_personal (nombres, apellido_paterno, apellido_materno)',
    )
        .order('fecha', ascending: false)
        .order('hora', ascending: false);
    return (data as List)
        .map((e) => Comensal.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Comensal?> _selectOneJoined(String idComensal) async {
    final data = await _client
        .from('comensales')
        .select(
      'id_comensal, fecha, hora, comida, fk_personal, '
          'personal:fk_personal (nombres, apellido_paterno, apellido_materno)',
    )
        .eq('id_comensal', idComensal)
        .maybeSingle();
    if (data == null) return null;
    return Comensal.fromJson(data as Map<String, dynamic>);
  }

  Future<void> _fetchAll() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await _selectAllJoined();
      setState(() {
        _items
          ..clear()
          ..addAll(list);
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
      _snack('Error al cargar: $e');
    }
  }

  void _setupRealtime() {
    _channel = _client.channel('public:comensales');

    // INSERT
    _channel!
        .onPostgresChanges(
      event: PostgresChangeEvent.insert,
      schema: 'public',
      table: 'comensales',
      callback: (payload) async {
        final id = payload.newRecord?['id_comensal'] as String?;
        if (id == null) return;
        final joined = await _selectOneJoined(id);
        if (joined == null || !mounted) return;
        setState(() {
          _items.insert(0, joined);
          _sortItems();
        });
      },
    )
    // UPDATE
        .onPostgresChanges(
      event: PostgresChangeEvent.update,
      schema: 'public',
      table: 'comensales',
      callback: (payload) async {
        final id = payload.newRecord?['id_comensal'] as String?;
        if (id == null) return;
        final joined = await _selectOneJoined(id);
        if (joined == null || !mounted) return;
        final idx = _items.indexWhere((x) => x.idComensal == id);
        setState(() {
          if (idx >= 0) {
            _items[idx] = joined;
          } else {
            _items.insert(0, joined);
          }
          _sortItems();
        });
      },
    )
    // DELETE
        .onPostgresChanges(
      event: PostgresChangeEvent.delete,
      schema: 'public',
      table: 'comensales',
      callback: (payload) {
        final id = payload.oldRecord?['id_comensal'] as String?;
        if (id == null || !mounted) return;
        setState(() {
          _items.removeWhere((x) => x.idComensal == id);
        });
      },
    )
        .subscribe();
  }

  void _sortItems() {
    _items.sort((a, b) {
      final f = b.fecha.compareTo(a.fecha);
      return f != 0 ? f : b.hora.compareTo(a.hora);
    });
  }

  @override
  void dispose() {
    _channel?.unsubscribe();
    super.dispose();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _deleteComensal(String idComensal) async {
    try {
      // Pedimos que devuelva la fila borrada para verificar que realmente existía.
      final deleted = await _client
          .from('comensales')
          .delete()
          .eq('id_comensal', idComensal)
          .select()
          .maybeSingle(); // <-- si no borró nada, será null

      if (deleted == null) {
        _snack('No se eliminó ninguna fila (verifica el ID o RLS).');
        // Refrescamos para reconciliar la UI con la DB
        await _fetchAll();
        return;
      }

      _snack('Registro eliminado.');
      // Aun con Realtime, refrescamos para asegurar estado consistente.
      await _fetchAll();
    } on PostgrestException catch (e) {
      _snack('No se pudo eliminar: ${e.message}');
      await _fetchAll();
    } catch (e) {
      _snack('Error: $e');
      await _fetchAll();
    }
  }

  void _editarComensal(Comensal c) {
    Navigator.of(context)
        .push(
      MaterialPageRoute(
        builder: (_) => ComensalEditPage(comensal: c),
      ),
    )
        .then((ok) {
      if (ok == true) _fetchAll();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Registro de comensales'),
        actions: [
          IconButton(
            onPressed: _fetchAll,
            tooltip: 'Actualizar',
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      drawer: const _AppDrawer(current: _AppMenuOption.comensales),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(
                    child: Text(
                      'Error: $_error',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  )
                : Column(
                    children: [
                      const _HeaderRow(),
                      const Divider(height: 1),
                      Expanded(
                        child: ListView.separated(
                          itemCount: _items.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, i) => _ComensalRow(
                            c: _items[i],
                            onEditar: _editarComensal,
                            onEliminar: _deleteComensal,
                          ),
                        ),
                      ),
                    ],
                  ),
      ),
    );
  }
}

class _AppDrawer extends StatelessWidget {
  final _AppMenuOption current;
  const _AppDrawer({required this.current});

  void _handleSelect(BuildContext context, _AppMenuOption value) {
    final navigator = Navigator.of(context);
    navigator.pop();
    if (value == current) return;
    Future.microtask(() {
      if (value == _AppMenuOption.comensales) {
        navigator.popUntil((route) => route.isFirst);
      } else {
        navigator.push(
          MaterialPageRoute(builder: (_) => const PersonalFormPage()),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    Widget destination({
      required _AppMenuOption option,
      required IconData icon,
      required String label,
    }) {
      final selected = option == current;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: ListTile(
          leading: Icon(icon),
          title: Text(label),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          selected: selected,
          selectedTileColor: colorScheme.primaryContainer,
          selectedColor: colorScheme.onPrimaryContainer,
          onTap: () => _handleSelect(context, option),
        ),
      );
    }

    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 16, 12),
              child: Text(
                'Menú principal',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  destination(
                    option: _AppMenuOption.comensales,
                    icon: Icons.restaurant_menu,
                    label: 'Registro de comensales',
                  ),
                  destination(
                    option: _AppMenuOption.personal,
                    icon: Icons.badge,
                    label: 'Registro de personal',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeaderRow extends StatelessWidget {
  const _HeaderRow();
  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          _Cell('Fecha', header: true, flex: 16),
          _Cell('Hora', header: true, flex: 16),
          _Cell('Comida', header: true, flex: 22),
          _Cell('Nombre completo', header: true, flex: 28),
          _Cell('DNI', header: true, flex: 14),
          _Cell('', header: true, flex: 4), // acciones
        ],
      ),
    );
  }
}

class _ComensalRow extends StatelessWidget {
  final Comensal c;
  final void Function(Comensal c) onEditar;
  final void Function(String idComensal) onEliminar;
  const _ComensalRow({
    required this.c,
    required this.onEditar,
    required this.onEliminar,
  });
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          _Cell(c.fecha, flex: 16),
          _Cell(c.hora, flex: 16),
          _Cell(c.comida ?? '—', flex: 22),
          _Cell(c.nombreCompleto, flex: 28),
          _Cell(c.fkPersonal, flex: 14),
          Expanded(
            flex: 4,
            child: Align(
              alignment: Alignment.centerRight,
              child: PopupMenuButton<String>(
                onSelected: (v) async {
                  if (v == 'editar') {
                    onEditar(c);
                  } else if (v == 'eliminar') {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (_) => AlertDialog(
                        title: const Text('Eliminar registro'),
                        content: Text(
                          '¿Eliminar el registro de ${c.nombreCompleto} '
                              'del ${c.fecha} a las ${c.hora}?',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('Cancelar'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('Eliminar'),
                          ),
                        ],
                      ),
                    );
                    if (ok == true) onEliminar(c.idComensal);
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'editar', child: Text('Editar comensal')),
                  PopupMenuItem(value: 'eliminar', child: Text('Eliminar comensal')),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  final String text;
  final bool header;
  final int flex;
  const _Cell(this.text, {this.header = false, this.flex = 1});
  @override
  Widget build(BuildContext context) {
    final style = header
        ? const TextStyle(fontWeight: FontWeight.w600)
        : const TextStyle();
    return Expanded(
      child: Text(text, style: style, overflow: TextOverflow.ellipsis),
      flex: flex,
    );
  }
}

/// ------------- Pantalla de edición de Comensal -------------
class ComensalEditPage extends StatefulWidget {
  final Comensal comensal;
  const ComensalEditPage({super.key, required this.comensal});

  @override
  State<ComensalEditPage> createState() => _ComensalEditPageState();
}

class _ComensalEditPageState extends State<ComensalEditPage> {
  final _client = Supabase.instance.client;
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _fecha;
  late final TextEditingController _hora;
  late final TextEditingController _dni;

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _fecha = TextEditingController(text: widget.comensal.fecha);
    _hora = TextEditingController(text: widget.comensal.hora);
    _dni = TextEditingController(text: widget.comensal.fkPersonal);
  }

  @override
  void dispose() {
    _fecha.dispose();
    _hora.dispose();
    _dni.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    try {
      // Nota: 'comida' es GENERATED ALWAYS y se recalculará en base a 'hora'
      await _client.from('comensales').update({
        'fecha': _fecha.text.trim(),
        'hora': _hora.text.trim(),
        'fk_personal': _dni.text.trim(),
      }).eq('id_comensal', widget.comensal.idComensal);

      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Actualizado')));
      Navigator.pop(context, true);
    } on PostgrestException catch (e) {
      // Puede fallar por la UNIQUE (fecha, comida, fk_personal)
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('No se pudo actualizar: ${e.message}')));
      setState(() => _saving = false);
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Error: $e')));
      setState(() => _saving = false);
    }
  }

  Future<void> _pickDate() async {
    final parts = _fecha.text.split('-');
    final now = DateTime.now();
    final initial = (parts.length == 3)
        ? DateTime(
      int.tryParse(parts[0]) ?? now.year,
      int.tryParse(parts[1]) ?? now.month,
      int.tryParse(parts[2]) ?? now.day,
    )
        : now;
    final picked = await showDatePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      initialDate: initial,
    );
    if (picked != null) {
      _fecha.text = picked.toIso8601String().substring(0, 10);
    }
  }

  Future<void> _pickTime() async {
    final parts = _hora.text.split(':');
    final initial = TimeOfDay(
      hour: int.tryParse(parts.elementAt(0)) ?? 12,
      minute: int.tryParse(parts.elementAt(1)) ?? 0,
    );
    final picked = await showTimePicker(context: context, initialTime: initial);
    if (picked != null) {
      final hh = picked.hour.toString().padLeft(2, '0');
      final mm = picked.minute.toString().padLeft(2, '0');
      _hora.text = '$hh:$mm:00';
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.comensal;
    return Scaffold(
      appBar: AppBar(title: Text('Editar comensal (${c.idComensal})')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: AbsorbPointer(
          absorbing: _saving,
          child: Form(
            key: _formKey,
            child: Column(
              children: [
                Row(children: [
                  Expanded(
                    child: TextFormField(
                      controller: _fecha,
                      decoration: InputDecoration(
                        labelText: 'Fecha (YYYY-MM-DD)',
                        suffixIcon: IconButton(
                          onPressed: _pickDate,
                          icon: const Icon(Icons.date_range),
                        ),
                      ),
                      validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Requerido' : null,
                    ),
                  ),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: TextFormField(
                      controller: _hora,
                      decoration: InputDecoration(
                        labelText: 'Hora (HH:mm:ss)',
                        suffixIcon: IconButton(
                          onPressed: _pickTime,
                          icon: const Icon(Icons.schedule),
                        ),
                      ),
                      validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Requerido' : null,
                    ),
                  ),
                ]),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _dni,
                  decoration: const InputDecoration(labelText: 'DNI'),
                  validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Requerido' : null,
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton(
                        onPressed: _save,
                        child: _saving
                            ? const SizedBox(
                            height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Text('Guardar'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  'La columna "comida" se calcula automáticamente según la hora.\n'
                      'La combinación (fecha, comida, DNI) debe ser única.',
                  style: TextStyle(fontSize: 12),
                )
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// ------------- Registro de Personal -------------
class PersonalFormPage extends StatefulWidget {
  const PersonalFormPage({super.key});

  @override
  State<PersonalFormPage> createState() => _PersonalFormPageState();
}

class _PersonalFormPageState extends State<PersonalFormPage> {
  final _client = Supabase.instance.client;
  final _formKey = GlobalKey<FormState>();

  final TextEditingController _idPersonal = TextEditingController();
  final TextEditingController _tipoDocumento = TextEditingController();
  final TextEditingController _nacionalidad = TextEditingController();
  final TextEditingController _apellidoPaterno = TextEditingController();
  final TextEditingController _apellidoMaterno = TextEditingController();
  final TextEditingController _nombres = TextEditingController();
  final TextEditingController _fkDistrito = TextEditingController();
  final TextEditingController _usuarioRegistro = TextEditingController();

  bool _saving = false;

  List<TextEditingController> get _allControllers => [
        _idPersonal,
        _tipoDocumento,
        _nacionalidad,
        _apellidoPaterno,
        _apellidoMaterno,
        _nombres,
        _fkDistrito,
        _usuarioRegistro,
      ];

  void _applyDefaults() {
    _tipoDocumento.text = 'DNI';
    _nacionalidad.text = 'Peruana';
    _fkDistrito.text = '211101';
    _usuarioRegistro.text = 'deyvi.rodrigo@gmail.com';
  }

  @override
  void initState() {
    super.initState();
    _applyDefaults();
  }

  @override
  void dispose() {
    for (final controller in _allControllers) {
      controller.dispose();
    }
    super.dispose();
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    bool requiredField = false,
    TextInputType? keyboardType,
    int? maxLength,
    Widget? suffixIcon,
    bool readOnly = false,
    VoidCallback? onTap,
  }) {
    return TextFormField(
      controller: controller,
      decoration: InputDecoration(
        labelText: label,
        suffixIcon: suffixIcon,
      ),
      readOnly: readOnly,
      onTap: onTap,
      keyboardType: keyboardType,
      maxLength: maxLength,
      validator: requiredField
          ? (value) => (value == null || value.trim().isEmpty) ? 'Requerido' : null
          : null,
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    try {
      final data = <String, dynamic>{
        'id_personal': _idPersonal.text.trim(),
        'tipo_documento': _tipoDocumento.text.trim(),
        'nacionalidad': _nacionalidad.text.trim(),
        'apellido_paterno': _apellidoPaterno.text.trim(),
        'apellido_materno': _apellidoMaterno.text.trim(),
        'nombres': _nombres.text.trim(),
        'fk_distrito': _fkDistrito.text.trim(),
        'usuario_registro': _usuarioRegistro.text.trim(),
      };

      await _client.from('personal').insert(data);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Personal registrado')));
      for (final controller in _allControllers) {
        controller.clear();
      }
      _formKey.currentState!.reset();
      _applyDefaults();
    } on PostgrestException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo registrar: ${e.message}')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Registro de personal'),
      ),
      drawer: const _AppDrawer(current: _AppMenuOption.personal),
      body: SafeArea(
        child: AbsorbPointer(
          absorbing: _saving,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildTextField(
                    controller: _idPersonal,
                    label: 'ID personal',
                    requiredField: true,
                  ),
                  const SizedBox(height: 12),
                  _buildTextField(
                    controller: _tipoDocumento,
                    label: 'Tipo de documento',
                    requiredField: true,
                  ),
                  const SizedBox(height: 12),
                  _buildTextField(
                    controller: _nacionalidad,
                    label: 'Nacionalidad',
                    requiredField: true,
                  ),
                  const SizedBox(height: 12),
                  _buildTextField(
                    controller: _apellidoPaterno,
                    label: 'Apellido paterno',
                    requiredField: true,
                  ),
                  const SizedBox(height: 12),
                  _buildTextField(
                    controller: _apellidoMaterno,
                    label: 'Apellido materno',
                    requiredField: true,
                  ),
                  const SizedBox(height: 12),
                  _buildTextField(
                    controller: _nombres,
                    label: 'Nombres',
                    requiredField: true,
                  ),
                  const SizedBox(height: 12),
                  _buildTextField(
                    controller: _fkDistrito,
                    label: 'Distrito (código)',
                    requiredField: true,
                    maxLength: 6,
                  ),
                  const SizedBox(height: 12),
                  _buildTextField(
                    controller: _usuarioRegistro,
                    label: 'Usuario de registro',
                    requiredField: true,
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _saving ? null : _save,
                    child: _saving
                        ? const SizedBox(
                            height: 16,
                            width: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Registrar personal'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
