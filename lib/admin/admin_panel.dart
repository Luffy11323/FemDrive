import 'package:femdrive/shared/notifications.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'app_utils.dart';
import 'analytics_and_maps.dart';
import 'package:femdrive/main.dart' as global;

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
      debugShowCheckedModeBanner: false,
      home: const AdminPanelHome(),
    );
  }
}

class AdminPanelHome extends StatefulWidget {
  const AdminPanelHome({super.key});

  @override
  AdminPanelHomeState createState() => AdminPanelHomeState();
}

class AdminPanelHomeState extends State<AdminPanelHome> {
  // REMOVE this unused variable:
  // bool _isDrawerOpen = false;
  
  String _currentPage = 'dashboard';
  // ignore: unused_field
  GoogleMapController? _mapController;
  final _searchController = TextEditingController();
  String? _selectedStatus;
  DateTimeRange? _selectedDateRange;
  bool? _selectedVerificationStatus;
  final Map<String, bool> _expandedStates = {};
  
  // ADD: GlobalKey for Scaffold to access drawer programmatically
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  void initState() {
    super.initState();
    NotificationService.onEmergencyNotification = () {
      Fluttertoast.showToast(msg: 'New Emergency Alert!');
    };
  }

  // FIXED: Simplified drawer toggle
  void _toggleDrawer() {
    if (_scaffoldKey.currentState?.isDrawerOpen ?? false) {
      Navigator.of(context).pop(); // Close drawer
    } else {
      _scaffoldKey.currentState?.openDrawer(); // Open drawer
    }
  }

  void _logout() async {
    try {
      await FirebaseAuth.instance.signOut();
      global.navigatorKey.currentState?.pushReplacementNamed('/login');
    } catch (e) {
      Fluttertoast.showToast(msg: 'Logout failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (_currentPage != 'dashboard' && MediaQuery.of(context).size.width <= 600) {
          setState(() {
            _currentPage = 'dashboard';
          });
        }
      },
      child: Scaffold(
        key: _scaffoldKey, // ADD: Attach the GlobalKey here
        appBar: AppBar(
          title: const Text('Admin Panel'),
          // FIXED: Leading icon for mobile
          leading: MediaQuery.of(context).size.width <= 600
              ? IconButton(
                  icon: const Icon(Icons.menu),
                  onPressed: _toggleDrawer,
                )
              : null,
          actions: [
            IconButton(
              icon: const Icon(Icons.search),
              onPressed: () => _showSearchDialog(context),
            ),
            IconButton(
              icon: const Icon(Icons.logout),
              onPressed: _logout,
            ),
            IconButton(
              icon: const Icon(Icons.notifications),
              onPressed: () => setState(() => _currentPage = 'emergencies'),
            ),
          ],
        ),
        // FIXED: Drawer should always be defined for mobile
        drawer: MediaQuery.of(context).size.width <= 600
            ? Drawer(
                child: _buildSidebar(context),
              )
            : null,
        body: LayoutBuilder(
          builder: (context, constraints) {
            final screenWidth = constraints.maxWidth;
            if (screenWidth <= 600) {
              return _buildMobileLayout(context);
            } else if (screenWidth <= 1200) {
              return _buildTabletLayout(context);
            } else {
              return _buildDesktopLayout(context);
            }
          },
        ),
      ),
    );
  }

  // REMOVE: This method is no longer needed
  // Widget? _buildLeadingIcon(BuildContext context) { ... }

  Widget _buildSidebar(BuildContext context) {
    return Container(
      color: Theme.of(context).cardColor,
      child: ListView(
        children: [
          const DrawerHeader(
            decoration: BoxDecoration(color: Colors.blue),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.admin_panel_settings, size: 48, color: Colors.white),
                SizedBox(height: 8),
                Text(
                  'Admin Panel',
                  style: TextStyle(fontSize: 24, color: Colors.white, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
          _buildDrawerItem(
            context,
            icon: Icons.dashboard,
            title: 'Dashboard',
            page: 'dashboard',
          ),
          _buildDrawerItem(
            context,
            icon: Icons.warning,
            title: 'Emergencies',
            page: 'emergencies',
          ),
          _buildDrawerItem(
            context,
            icon: Icons.directions_car,
            title: 'Rides',
            page: 'rides',
          ),
          _buildDrawerItem(
            context,
            icon: Icons.person,
            title: 'Users',
            page: 'users',
          ),
          _buildDrawerItem(
            context,
            icon: Icons.drive_eta,
            title: 'Drivers',
            page: 'drivers',
          ),
          _buildDrawerItem(
            context,
            icon: Icons.verified,
            title: 'Driver Verifications',
            page: 'driver_verifications',
          ),
          _buildDrawerItem(
            context,
            icon: Icons.star,
            title: 'Ratings',
            page: 'ratings',
          ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.all(16.0),
            child: Text(
              'v1.0.0',
              style: TextStyle(color: Colors.grey, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  // NEW: Helper method for drawer items with proper navigation
  Widget _buildDrawerItem(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String page,
  }) {
    final isSelected = _currentPage == page;
    
    return ListTile(
      leading: Icon(
        icon,
        color: isSelected ? Theme.of(context).primaryColor : null,
      ),
      title: Text(
        title,
        style: TextStyle(
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          color: isSelected ? Theme.of(context).primaryColor : null,
        ),
      ),
      selected: isSelected,
      selectedTileColor: Theme.of(context).primaryColor.withValues(alpha: 0.1),
      onTap: () {
        setState(() => _currentPage = page);
        // Close drawer on mobile after selection
        if (MediaQuery.of(context).size.width <= 600) {
          Navigator.pop(context);
        }
      },
    );
  }

  // Rest of your methods remain the same...
  Widget _buildMainContent(BuildContext context) {
    switch (_currentPage) {
      case 'dashboard':
        return _buildDashboard(context);
      case 'emergencies':
        return _buildEmergencies(context);
      case 'rides':
        return _buildDataTable(context, 'rides');
      case 'users':
        return _buildUsersPage(context);
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

  Widget _buildMobileLayout(BuildContext context) {
    return _buildMainContent(context);
  }

  Widget _buildTabletLayout(BuildContext context) {
    return Row(
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final sidebarWidth = constraints.maxWidth * 0.2;
            return SizedBox(
              width: sidebarWidth.clamp(200, 250),
              child: _buildSidebar(context),
            );
          },
        ),
        Expanded(child: _buildMainContent(context)),
      ],
    );
  }

  Widget _buildDesktopLayout(BuildContext context) {
    return Row(
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final sidebarWidth = constraints.maxWidth * 0.25;
            return SizedBox(
              width: sidebarWidth.clamp(250, 300),
              child: _buildSidebar(context),
            );
          },
        ),
        Expanded(child: _buildMainContent(context)),
      ],
    );
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Emergencies'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => setState(() => _currentPage = 'dashboard'),
        ),
      ),
      body: StreamBuilder(
        stream: FirebaseFirestore.instance
            .collection(AppPaths.emergenciesCollection)
            .orderBy('createdAt', descending: true)
            .snapshots(),
        builder: (context, AsyncSnapshot<QuerySnapshot> snapshot) {
          if (snapshot.hasError) {
            return const Center(child: Text('Error loading emergencies data'));
          }
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          if (snapshot.data!.docs.isEmpty) {
            return const Center(child: Text('No emergencies found'));
          }
          if (snapshot.data!.docs.isNotEmpty && snapshot.data!.docs.first['emergencyTriggered'] == true) {
            showAdminEmergencyAlert(
              rideId: snapshot.data!.docs.first['rideId'],
              title: 'New Emergency',
              body: 'A new emergency has been reported.',
            );
          }
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
      ),
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
              if (MediaQuery.of(context).size.width > 300)
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
                  columnSpacing: 16.0,
                  dataRowMinHeight: 48.0,
                  dataRowMaxHeight: 48.0,
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
                        DataCell(Text(doc['verified']?.toString() ?? '')),
                        DataCell(Text(doc['verifiedCnic']?.toString() ?? '')),
                        DataCell(Text(doc['verifiedLicense']?.toString() ?? '')),
                        DataCell(Text(doc['trustScore']?.toString() ?? '')),
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

  Widget _buildUsersPage(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: TextField(
            controller: _searchController,
            decoration: const InputDecoration(
              hintText: 'Search by UID, Username, Phone, or Ride ID',
              prefixIcon: Icon(Icons.search),
            ),
            onChanged: (value) => setState(() {}),
          ),
        ),
        Expanded(
          child: StreamBuilder(
            stream: FirebaseFirestore.instance
                .collection(AppPaths.usersCollection)
                .orderBy(AppFields.createdAt, descending: true)
                .snapshots(),
            builder: (context, AsyncSnapshot<QuerySnapshot> snapshot) {
              if (snapshot.hasError) {
                return const Center(child: Text('Error loading users data'));
              }
              if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
              final users = snapshot.data!.docs.toList();
              if (users.isEmpty) return const Center(child: Text('No users found'));
              return ListView.builder(
                itemCount: users.length,
                itemExtent: 60,
                itemBuilder: (context, index) {
                  final doc = users[index];
                  final data = doc.data() as Map<String, dynamic>;
                  final uid = doc.id;
                  _expandedStates.putIfAbsent(uid, () => false);
                  return Card(
                    margin: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 8.0),
                    child: ExpansionPanelList(
                      elevation: 1,
                      expansionCallback: (int panelIndex, bool isExpanded) {
                        setState(() {
                          _expandedStates[uid] = !isExpanded;
                        });
                      },
                      children: [
                        ExpansionPanel(
                          headerBuilder: (context, isExpanded) => ListTile(
                            title: Text(data[AppFields.username] ?? 'Unnamed User'),
                          ),
                          body: _buildInfoPanel(data, uid),
                          isExpanded: _expandedStates[uid] ?? false,
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildInfoPanel(Map<String, dynamic> data, String uid) {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (data[AppFields.phone] != null)
            _buildEditableField('Phone', AppFields.phone, data[AppFields.phone].toString(), data, uid),
          if (data[AppFields.role] != null)
            _buildEditableField('Role', AppFields.role, data[AppFields.role].toString(), data, uid),
          if (data[AppFields.verified] != null)
            _buildEditableField('Verified', AppFields.verified, data[AppFields.verified].toString(), data, uid),
          if (data[AppFields.trustScore] != null)
            _buildEditableField('Trust Score', AppFields.trustScore, data[AppFields.trustScore].toString(), data, uid),
          if (data[AppFields.cnicNumber] != null)
            _buildEditableField('CNIC', AppFields.cnicNumber, data[AppFields.cnicNumber].toString(), data, uid),
          if (data[AppFields.documentsUploaded] != null)
            _buildEditableField(
                'Documents Uploaded', AppFields.documentsUploaded, data[AppFields.documentsUploaded].toString(), data, uid),
          if (data[AppFields.role] == 'driver') ...[
            if (data[AppFields.carType] != null)
              _buildEditableField('Car Type', AppFields.carType, data[AppFields.carType].toString(), data, uid),
            if (data[AppFields.carModel] != null)
              _buildEditableField('Car Model', AppFields.carModel, data[AppFields.carModel].toString(), data, uid),
            if (data[AppFields.altContact] != null)
              _buildEditableField('Alt Contact', AppFields.altContact, data[AppFields.altContact].toString(), data, uid),
            if (data[AppFields.verifiedLicense] != null)
              _buildEditableField(
                  'License Verified', AppFields.verifiedLicense, data[AppFields.verifiedLicense].toString(), data, uid),
            if (data[AppFields.awaitingVerification] != null)
              _buildEditableField('Awaiting Verification', AppFields.awaitingVerification,
                  data[AppFields.awaitingVerification].toString(), data, uid),
          ],
          _buildRidePanel(data[AppFields.uid]),
        ],
      ),
    );
  }

  Widget _buildRidePanel(String? uid) {
    return StreamBuilder(
      stream: uid != null
          ? FirebaseFirestore.instance
              .collection(AppPaths.ridesCollection)
              .where(AppFields.riderId, isEqualTo: uid)
              .orderBy(AppFields.createdAt, descending: true)
              .snapshots()
          : null,
      builder: (context, AsyncSnapshot<QuerySnapshot> snapshot) {
        if (snapshot.hasError) {
          return const SizedBox.shrink();
        }
        if (!snapshot.hasData) return const SizedBox.shrink();
        final rides = snapshot.data!.docs;
        if (rides.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.all(8.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Ride History', style: Theme.of(context).textTheme.headlineSmall),
              Column(
                children: rides.map((doc) {
                  final rideData = doc.data() as Map<String, dynamic>;
                  return ListTile(
                    title: Text('Ride #${doc.id}'),
                    subtitle: Text(
                      'Status: ${rideData[AppFields.status] ?? ''}, '
                      'Fare: ${rideData[AppFields.fare] ?? ''}, '
                      'Emergency: ${rideData[AppFields.emergencyTriggered] ?? ''}',
                    ),
                    trailing: Text(rideData[AppFields.createdAt]?.toDate().toString() ?? ''),
                  );
                }).toList(),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildEditableField(String label, String fieldKey, String value, Map<String, dynamic> data, String uid) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.0),
      child: Row(
        children: [
          Text('$label: ', style: const TextStyle(fontWeight: FontWeight.bold)),
          Expanded(
            child: TextField(
              controller: TextEditingController(text: value),
              onChanged: (newValue) {
                data[fieldKey] = _parseField(fieldKey, newValue);
                AdminService.updateData(AppPaths.usersCollection, uid, data);
              },
              decoration: const InputDecoration(border: InputBorder.none),
            ),
          ),
        ],
      ),
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
              if (MediaQuery.of(context).size.width > 300)
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
              if (snapshot.data!.docs.isEmpty) return const Center(child: Text('No data found'));
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columnSpacing: 16.0,
                  dataRowMinHeight: 48.0,
                  dataRowMaxHeight: 48.0,
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
              Text('Location: ${doc['rideSnapshot'][AppFields.pickup]}'),
              SizedBox(
                height: 200,
                child: GoogleMap(
                  initialCameraPosition: CameraPosition(
                    target: LatLng(
                      doc['rideSnapshot'][AppFields.pickupLat] ?? 37.7749,
                      doc['rideSnapshot'][AppFields.pickupLng] ?? -122.4194,
                    ),
                    zoom: 15,
                  ),
                  markers: {
                    Marker(
                      markerId: MarkerId(doc.id),
                      position: LatLng(
                        doc['rideSnapshot'][AppFields.pickupLat] ?? 37.7749,
                        doc['rideSnapshot'][AppFields.pickupLng] ?? -122.4194,
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
