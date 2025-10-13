import 'package:femdrive/shared/notifications.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'app_utils.dart';
import 'analytics_and_maps.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService.init();
  runApp(const AdminPanelApp());
}

class AdminPanelApp extends StatelessWidget {
  const AdminPanelApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.light(),
      darkTheme: ThemeData.dark(),
      themeMode: ThemeMode.system,
      home: const AdminPanelHome(),
    );
  }
}

class AdminPanelHome extends StatefulWidget {
  const AdminPanelHome({super.key});

  @override
  // ignore: library_private_types_in_public_api
  _AdminPanelHomeState createState() => _AdminPanelHomeState();
}

class _AdminPanelHomeState extends State<AdminPanelHome> {
  bool _isSidebarOpen = true; // Changed to non-final for toggling
  String _currentPage = 'dashboard';
  // ignore: unused_field
  GoogleMapController? _mapController;
  final _searchController = TextEditingController();
  String? _selectedStatus;
  DateTimeRange? _selectedDateRange;
  bool? _selectedVerificationStatus;

  @override
  void initState() {
    super.initState();
    NotificationService.onEmergencyNotification = () {
      Fluttertoast.showToast(msg: 'New Emergency Alert!');
    };
  }

  // Toggle sidebar visibility
  void _toggleSidebar() {
    setState(() {
      _isSidebarOpen = !_isSidebarOpen;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin Panel'),
        leading: MediaQuery.of(context).size.width <= 600
            ? IconButton(
                icon: Icon(_isSidebarOpen ? Icons.close : Icons.menu),
                onPressed: _toggleSidebar,
              )
            : null,
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () => _showSearchDialog(context),
          ),
          IconButton(
            icon: const Icon(Icons.notifications),
            onPressed: () => setState(() => _currentPage = 'emergencies'),
          ),
        ],
      ),
      drawer: MediaQuery.of(context).size.width <= 600
          ? _buildSidebar(context)
          : null,
      body: Row(
        children: [
          if (_isSidebarOpen && MediaQuery.of(context).size.width > 600)
            SizedBox(width: 250, child: _buildSidebar(context)),
          Expanded(child: _buildMainContent(context)),
        ],
      ),
    );
  }

  Widget _buildSidebar(BuildContext context) {
    return Drawer(
      child: ListView(
        children: [
          const DrawerHeader(child: Text('Admin Panel', style: TextStyle(fontSize: 24))),
          ListTile(
            leading: const Icon(Icons.dashboard),
            title: const Text('Dashboard'),
            onTap: () {
              setState(() => _currentPage = 'dashboard');
              if (MediaQuery.of(context).size.width <= 600) Navigator.pop(context);
            },
          ),
          ListTile(
            leading: const Icon(Icons.warning),
            title: const Text('Emergencies'),
            onTap: () {
              setState(() => _currentPage = 'emergencies');
              if (MediaQuery.of(context).size.width <= 600) Navigator.pop(context);
            },
          ),
          ListTile(
            leading: const Icon(Icons.directions_car),
            title: const Text('Rides'),
            onTap: () {
              setState(() => _currentPage = 'rides');
              if (MediaQuery.of(context).size.width <= 600) Navigator.pop(context);
            },
          ),
          ListTile(
            leading: const Icon(Icons.person),
            title: const Text('Users'),
            onTap: () {
              setState(() => _currentPage = 'users');
              if (MediaQuery.of(context).size.width <= 600) Navigator.pop(context);
            },
          ),
          ListTile(
            leading: const Icon(Icons.drive_eta),
            title: const Text('Drivers'),
            onTap: () {
              setState(() => _currentPage = 'drivers');
              if (MediaQuery.of(context).size.width <= 600) Navigator.pop(context);
            },
          ),
          ListTile(
            leading: const Icon(Icons.verified),
            title: const Text('Driver Verifications'),
            onTap: () {
              setState(() => _currentPage = 'driver_verifications');
              if (MediaQuery.of(context).size.width <= 600) Navigator.pop(context);
            },
          ),
          ListTile(
            leading: const Icon(Icons.star),
            title: const Text('Ratings'),
            onTap: () {
              setState(() => _currentPage = 'ratings');
              if (MediaQuery.of(context).size.width <= 600) Navigator.pop(context);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildMainContent(BuildContext context) {
    switch (_currentPage) {
      case 'dashboard':
        return _buildDashboard(context);
      case 'emergencies':
        return _buildEmergencies(context);
      case 'rides':
        return _buildDataTable(context, 'rides');
      case 'users':
        return _buildDataTable(context, 'users');
      case 'drivers':
        return _buildDataTable(context, 'drivers');
      case 'driver_verifications':
        return _buildDriverVerificationPage(context);
      case 'ratings':
        return _buildDataTable(context, 'ratings');
      default:
        return const Center(child: Text('Select a page'));
    }
  }

  Widget _buildDashboard(BuildContext context) {
    return StreamBuilder(
      stream: FirebaseFirestore.instance.collection(AppPaths.ridesCollection).snapshots(),
      builder: (context, AsyncSnapshot<QuerySnapshot> snapshot) {
        if (snapshot.hasError) {
          return const Center(child: Text('Error loading rides data'));
        }
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
        int activeRides = snapshot.data!.docs.where((d) => d['status'] == RideStatus.inProgress).length;
        return Column(
          children: [
            StreamBuilder(
              stream: FirebaseFirestore.instance
                  .collection(AppPaths.emergenciesCollection)
                  .where('resolved', isEqualTo: false)
                  .snapshots(),
              builder: (context, AsyncSnapshot<QuerySnapshot> emergencySnapshot) {
                if (emergencySnapshot.hasError) {
                  return const Center(child: Text('Error loading emergencies data'));
                }
                if (!emergencySnapshot.hasData) return const Center(child: CircularProgressIndicator());
                int emergencyCount = emergencySnapshot.data!.docs.length;
                return Row(
                  children: [
                    _buildKpiCard('Active Rides', activeRides.toString(), Icons.directions_car),
                    _buildKpiCard(
                      'Emergencies',
                      emergencyCount.toString(),
                      Icons.warning,
                      onTap: () => setState(() => _currentPage = 'emergencies'),
                    ),
                  ],
                );
              },
            ),
            Container(
              height: 200,
              padding: const EdgeInsets.all(16.0),
              child: RideStatusChart(),
            ),
            Expanded(
              child: GoogleMap(
                initialCameraPosition: const CameraPosition(target: LatLng(37.7749, -122.4194), zoom: 10),
                onMapCreated: (controller) => _mapController = controller,
                markers: snapshot.data!.docs
                    .where((d) => d['pickupLat'] != null && d['pickupLng'] != null)
                    .map((d) => Marker(
                          markerId: MarkerId(d.id),
                          position: LatLng(d['pickupLat'], d['pickupLng']),
                          infoWindow: InfoWindow(title: 'Ride ${d.id}'),
                        ))
                    .toSet(),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildKpiCard(String title, String value, IconData icon, {VoidCallback? onTap}) {
    return Expanded(
      child: Card(
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
                Icon(icon, size: 40),
                Text(title, style: const TextStyle(fontSize: 16)),
                Text(value, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmergencies(BuildContext context) {
    return StreamBuilder(
      stream: FirebaseFirestore.instance.collection(AppPaths.emergenciesCollection).orderBy('createdAt', descending: true).snapshots(),
      builder: (context, AsyncSnapshot<QuerySnapshot> snapshot) {
        if (snapshot.hasError) {
          return const Center(child: Text('Error loading emergencies data'));
        }
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
        if (snapshot.data!.docs.isNotEmpty && snapshot.data!.docs.first['emergencyTriggered'] == true) showAdminEmergencyAlert(rideId: snapshot.data!.docs.first['rideId'], title: 'New Emergency', body: 'A new emergency has been reported.');
        return ListView.builder(
          itemCount: snapshot.data!.docs.length,
          itemBuilder: (context, index) {
            var doc = snapshot.data!.docs[index];
            return Card(
              child: ListTile(
                leading: const Icon(Icons.warning, color: Colors.red),
                title: Text('Emergency #${doc.id} by ${doc['reportedBy']}'),
                subtitle: Text('Ride: ${doc['rideId']} | Time: ${doc['createdAt']}'),
                trailing: IconButton(
                  icon: const Icon(Icons.edit),
                  onPressed: () => _showEditDialog(context, AppPaths.emergenciesCollection, doc),
                ),
                onTap: () => _showEmergencyDetails(context, doc),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildDriverVerificationPage(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  decoration: const InputDecoration(
                    hintText: 'Search by Driver ID',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (value) => setState(() {}),
                ),
              ),
              DropdownButton<bool?>(
                hint: const Text('Verification Status'),
                value: _selectedVerificationStatus,
                items: const [
                  DropdownMenuItem(value: null, child: Text('All')),
                  DropdownMenuItem(value: true, child: Text('Verified')),
                  DropdownMenuItem(value: false, child: Text('Unverified')),
                ],
                onChanged: (value) => setState(() => _selectedVerificationStatus = value),
              ),
            ],
          ),
        ),
        Expanded(
          child: StreamBuilder(
            stream: AdminService.getDriverVerificationStream(_searchController.text, _selectedVerificationStatus),
            builder: (context, AsyncSnapshot<QuerySnapshot> snapshot) {
              if (snapshot.hasError) {
                return const Center(child: Text('Error loading driver verification data'));
              }
              if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columns: const [
                    DataColumn(label: Text('Driver ID')),
                    DataColumn(label: Text('Name')),
                    DataColumn(label: Text('Verified')),
                    DataColumn(label: Text('CNIC Verified')),
                    DataColumn(label: Text('License Verified')),
                    DataColumn(label: Text('Trust Score')),
                  ],
                  rows: snapshot.data!.docs.map((doc) {
                    return DataRow(
                      cells: [
                        DataCell(Text(doc.id)),
                        DataCell(Text(doc['username'] ?? '')),
                        DataCell(Text(doc['verified']?.toString() ?? 'false')),
                        DataCell(Text(doc['verifiedCnic']?.toString() ?? 'false')),
                        DataCell(Text(doc['verifiedLicense']?.toString() ?? 'false')),
                        DataCell(Text(doc['trustScore']?.toString() ?? '0.0')),
                      ],
                      onSelectChanged: (selected) => _showEditDialog(context, AppPaths.usersCollection, doc),
                    );
                  }).toList(),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildDataTable(BuildContext context, String collection) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  decoration: const InputDecoration(
                    hintText: 'Search by ID',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (value) => setState(() {}),
                ),
              ),
              DropdownButton<String>(
                hint: const Text('Status'),
                value: _selectedStatus,
                items: [
                  const DropdownMenuItem(value: null, child: Text('All')),
                  ...RideStatus.values.map((status) => DropdownMenuItem(value: status, child: Text(status))),
                ],
                onChanged: (value) => setState(() => _selectedStatus = value),
              ),
              IconButton(
                icon: const Icon(Icons.date_range),
                onPressed: () async {
                  final range = await showDateRangePicker(
                    context: context,
                    firstDate: DateTime(2020),
                    lastDate: DateTime.now(),
                  );
                  setState(() => _selectedDateRange = range);
                },
              ),
            ],
          ),
        ),
        Expanded(
          child: StreamBuilder(
            stream: AdminService.getFilteredStream(collection, _searchController.text, _selectedStatus, _selectedDateRange),
            builder: (context, AsyncSnapshot<QuerySnapshot> snapshot) {
              if (snapshot.hasError) {
                return const Center(child: Text('Error loading data'));
              }
              if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columns: _getColumns(collection),
                  rows: snapshot.data!.docs.map((doc) {
                    return DataRow(
                      cells: _getCells(collection, doc),
                      onSelectChanged: (selected) => _showEditDialog(context, collection, doc),
                    );
                  }).toList(),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  List<DataColumn> _getColumns(String collection) {
    switch (collection) {
      case 'rides':
        return const [
          DataColumn(label: Text('Ride ID')),
          DataColumn(label: Text('Status')),
          DataColumn(label: Text('Fare')),
          DataColumn(label: Text('Driver ID')),
          DataColumn(label: Text('Rider ID')),
        ];
      case 'users':
      case 'drivers':
        return const [
          DataColumn(label: Text('UID')),
          DataColumn(label: Text('Name')),
          DataColumn(label: Text('Phone')),
          DataColumn(label: Text('Verified')),
        ];
      case 'ratings':
        return const [
          DataColumn(label: Text('Ride ID')),
          DataColumn(label: Text('Rating')),
          DataColumn(label: Text('Comment')),
        ];
      default:
        return const [DataColumn(label: Text('ID'))];
    }
  }

  List<DataCell> _getCells(String collection, DocumentSnapshot doc) {
    switch (collection) {
      case 'rides':
        return [
          DataCell(Text(doc.id)),
          DataCell(Text(doc['status'] ?? '')),
          DataCell(Text(doc['fare']?.toString() ?? '')),
          DataCell(Text(doc['driverId'] ?? '')),
          DataCell(Text(doc['riderId'] ?? '')),
        ];
      case 'users':
      case 'drivers':
        return [
          DataCell(Text(doc.id)),
          DataCell(Text(doc['name'] ?? '')),
          DataCell(Text(doc['phone'] ?? '')),
          DataCell(Text(doc['verified']?.toString() ?? '')),
        ];
      case 'ratings':
        return [
          DataCell(Text(doc['rideId'] ?? '')),
          DataCell(Text(doc['rating']?.toString() ?? '')),
          DataCell(Text(doc['comment'] ?? '')),
        ];
      default:
        return [DataCell(Text(doc.id))];
    }
  }

  void _showSearchDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) {
        String searchQuery = '';
        return AlertDialog(
          title: const Text('Search'),
          content: TextField(
            onChanged: (value) => searchQuery = value,
            decoration: const InputDecoration(hintText: 'Enter rideId or userId'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () async {
                try {
                  var result = await AdminService.searchData(searchQuery);
                  // ignore: use_build_context_synchronously
                  Navigator.pop(context);
                  if (result != null) {
                    setState(() {
                      _currentPage = result['collection'];
                      _searchController.text = searchQuery;
                    });
                  } else {
                    Fluttertoast.showToast(msg: 'No results found for "$searchQuery"');
                  }
                } catch (e) {
                  // ignore: use_build_context_synchronously
                  Navigator.pop(context);
                  Fluttertoast.showToast(msg: 'Search failed: $e');
                }
              },
              child: const Text('Search'),
            ),
          ],
        );
      },
    );
  }

  void _showEditDialog(BuildContext context, String collection, DocumentSnapshot doc) {
    showDialog(
      context: context,
      builder: (context) {
        Map<String, dynamic> data = doc.data() as Map<String, dynamic>;
        return AlertDialog(
          title: Text('Edit $collection: ${doc.id}'),
          content: SingleChildScrollView(
            child: Column(
              children: data.entries.map((entry) {
                return TextField(
                  decoration: InputDecoration(labelText: entry.key),
                  controller: TextEditingController(text: entry.value.toString()),
                  onChanged: (value) => data[entry.key] = _parseField(entry.key, value),
                );
              }).toList(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () async {
                try {
                  await AdminService.updateData(collection, doc.id, data);
                  // ignore: use_build_context_synchronously
                  Navigator.pop(context);
                  Fluttertoast.showToast(msg: 'Updated successfully');
                } catch (e) {
                  Fluttertoast.showToast(msg: 'Update failed: $e');
                }
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

  void _showEmergencyDetails(BuildContext context, DocumentSnapshot doc) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('Emergency #${doc.id}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Ride ID: ${doc['rideId']}'),
              Text('Reported By: ${doc['reportedBy']}'),
              Text('Location: ${doc['rideSnapshot']['pickup']}'),
              SizedBox(
                height: 200,
                child: GoogleMap(
                  initialCameraPosition: CameraPosition(
                    target: LatLng(
                      doc['rideSnapshot']['pickupLat'] ?? 37.7749,
                      doc['rideSnapshot']['pickupLng'] ?? -122.4194,
                    ),
                    zoom: 15,
                  ),
                  markers: {
                    Marker(
                      markerId: MarkerId(doc.id),
                      position: LatLng(
                        doc['rideSnapshot']['pickupLat'] ?? 37.7749,
                        doc['rideSnapshot']['pickupLng'] ?? -122.4194,
                      ),
                    ),
                  },
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () async {
                try {
                  await AdminService.resolveEmergency(doc.id);
                  // ignore: use_build_context_synchronously
                  Navigator.pop(context);
                  Fluttertoast.showToast(msg: 'Emergency resolved');
                } catch (e) {
                  Fluttertoast.showToast(msg: 'Failed to resolve emergency: $e');
                }
              },
              child: const Text('Resolve'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  dynamic _parseField(String key, String value) {
    if (key.contains('verified') || key.contains('emergencyTriggered') || key.contains('awaitingVerification')) {
      return value.toLowerCase() == 'true';
    }
    if (key.contains('Lat') || key.contains('Lng') || key.contains('fare') || key.contains('trustScore')) {
      return double.tryParse(value);
    }
    if (key.contains('timestamp') || key.contains('At')) {
      try {
        return Timestamp.fromDate(DateTime.parse(value));
      } catch (_) {
        return null;
      }
    }
    return value;
  }
}