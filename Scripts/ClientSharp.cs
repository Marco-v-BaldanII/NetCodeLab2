using Godot;
using System;
using System.Net;
using System.Net.Sockets;
using System.Text;

public partial class ClientSharp : Node
{
    private const string ServerIp = "127.0.0.1";
    private const int TcpPort = 5000;
    private const int UdpPort = 5001;

    private Socket _tcpSocket;
    private Socket _udpSocket;
    private IPEndPoint _serverUdpEndpoint; 

    public override void _Ready()
    {
        // Initialize raw sockets
        _tcpSocket = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
        _udpSocket = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);

        // Define the server's UDP endpoint for sending/receiving
        _serverUdpEndpoint = new IPEndPoint(IPAddress.Parse(ServerIp), UdpPort);

        ConnectToServer(ServerIp);
        CallDeferred(nameof(SendInitialMessages));
    }

    private void ConnectToServer(string ipAddress)
    {
        //  TCP Connection Initiation ---
        IPEndPoint serverTcpEndpoint = new IPEndPoint(IPAddress.Parse(ipAddress), TcpPort);

        // Use ConnectAsync for non-blocking connection initiation. 
        _tcpSocket.ConnectAsync(serverTcpEndpoint).ContinueWith(task =>
        {
            if (task.IsFaulted)
            {
                GD.PrintErr($"TCP connection failed: {task.Exception.InnerException.Message}");
            }
            else
            {
                GD.Print("TCP connection established successfully.");
            }
        });

        // --- UDP Setup ---
        _udpSocket.Connect(_serverUdpEndpoint);
        GD.Print($"UDP client destination set to {ipAddress}:{UdpPort}");
    }

    private async void SendInitialMessages()
    {
        await ToSignal(GetTree().CreateTimer(2.0f), SceneTreeTimer.SignalName.Timeout);

        // Check Socket.Connected property for status
        if (_tcpSocket.Connected)
        {
            SendTcpMessage("Client: User_A is joining via TCP.");
        }
        else
        {
            GD.PrintErr("Cannot send initial TCP message: Not connected.");
        }

        SendUdpMessage("Client: User_A is sending a UDP message.");
    }

    private void SendTcpMessage(string message)
    {
        byte[] encodedData = Encoding.UTF8.GetBytes(message);
        byte[] fullPacket = new byte[4 + encodedData.Length];

        // Create the length prefix and combine arrays
        BitConverter.GetBytes((uint)encodedData.Length).CopyTo(fullPacket, 0);
        encodedData.CopyTo(fullPacket, 4);

        // Raw Socket Send
        _tcpSocket.Send(fullPacket);
        GD.Print($"Sent TCP message: {message}");
    }

    private void SendUdpMessage(string message)
    {
        byte[] encodedData = Encoding.UTF8.GetBytes(message);

        // Raw Socket Send (sends to the address set by Connect())
        _udpSocket.Send(encodedData);
        GD.Print($"Sent UDP message: {message}");
    }

    public override void _Process(double delta)
    {
        //  TCP Polling for Replies ---
        // Check the socket's connection status and Available data
        if (_tcpSocket.Connected && _tcpSocket.Available >= 4)
        {
            try
            {
                // Read the 4-byte length prefix
                byte[] lengthPrefix = new byte[4];
                _tcpSocket.Receive(lengthPrefix, 4, SocketFlags.None);
                uint packetLength = BitConverter.ToUInt32(lengthPrefix, 0);

                // Read the actual data (check again in case the rest hasn't arrived)
                if (_tcpSocket.Available >= packetLength)
                {
                    byte[] dataBuffer = new byte[packetLength];
                    _tcpSocket.Receive(dataBuffer, (int)packetLength, SocketFlags.None);

                    string receivedString = Encoding.UTF8.GetString(dataBuffer);
                    GD.Print($"Received TCP reply: {receivedString}");
                }
            }
            catch (SocketException e)
            {
                GD.PrintErr($"TCP Receive error: {e.Message}");
            }
        }

        // ---  UDP Polling for Replies ---
        // Check the socket's Available data without blocking
        if (_udpSocket.Available > 0)
        {
            try
            {

                // Get the size of the incoming packet
                int packetSize = _udpSocket.Available;
                byte[] dataBytes = new byte[packetSize];

                // Receive the data
                _udpSocket.Receive(dataBytes);

                string receivedString = Encoding.UTF8.GetString(dataBytes);
                GD.Print($"Received UDP reply: {receivedString}");
            }
            catch (SocketException e)
            {
                GD.PrintErr($"UDP Receive error: {e.Message}");
            }
        }
    }
}