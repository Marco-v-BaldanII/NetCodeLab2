using Godot;
using System.Net;
using System.Net.Sockets;
using System.Collections.Generic;
using System.Text;
using System;

public partial class ServerSharp : Node
{
	private const int TcpPort = 5000;
	private const int UdpPort = 5001;

	private Socket _tcpListener;
	private UdpClient _udpServer;

	// List to manage connected client sockets
	private List<Socket> _tcpPeers = new List<Socket>();

	public override void _Ready()
	{
		// TCP Setup 
		try
		{
			_tcpListener = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
			_tcpListener.Bind(new IPEndPoint(IPAddress.Any, TcpPort));
			_tcpListener.Listen(10); // Start listening, the 10 "backlog" is the amount of connections it can handle
			GD.Print($"TCP Server listening on port {TcpPort} (System.Net.Sockets).");
		}
		catch (Exception e)
		{
			GD.PrintErr($"TCP setup error: {e.Message}");
		}

		// UDP Setup 
		try
		{
			_udpServer = new UdpClient(UdpPort);
			GD.Print($"UDP Server listening on port {UdpPort} (System.Net.Sockets).");
		}
		catch (Exception e)
		{
			GD.PrintErr($"UDP setup error: {e.Message}");
		}
	}

	public override void _Process(double delta)
	{

		List<Socket> checkRead = new List<Socket>();

		// check for tcp connections
		checkRead.Add(_tcpListener);

		checkRead.AddRange(_tcpPeers);

		// Prevent blocking with socket.Select()
		Socket.Select(checkRead, null, null, 0);

		if (checkRead.Contains(_tcpListener))
		{
			try
			{
				// Accept is now non-blocking because Select guaranteed it's ready
				Socket newPeer = _tcpListener.Accept();
				_tcpPeers.Add(newPeer);
				GD.Print($"New TCP Client connected! Total peers: {_tcpPeers.Count}");

				// Answer back with the name of the server
				SendTcpMessage(newPeer, "Server_Godot_Online");

				// Remove the listener from the processing queue
				checkRead.Remove(_tcpListener);
			}
			catch (Exception e)
			{
				GD.PrintErr($"Accept error: {e.Message}");
			}
		}

		// Process TCP peers
		for (int i = 0; i < checkRead.Count; ++i)
		{
			Socket peer = checkRead[i];

			if (!peer.Connected) continue; 

			try
			{
				// Check if the socket has data available
				if (peer.Available > 0)
				{
					// Read the 4-byte length prefix
					byte[] lengthPrefix = new byte[4];
					int bytesRead = peer.Receive(lengthPrefix, 4, SocketFlags.None);
					if (bytesRead < 4) continue; // Not enough data for prefix, skip for now

					uint packetLength = BitConverter.ToUInt32(lengthPrefix, 0);

					// Read the actual data
					byte[] dataBuffer = new byte[packetLength];
					peer.Receive(dataBuffer, (int)packetLength, SocketFlags.None);

					string message = Encoding.UTF8.GetString(dataBuffer);
					GD.Print($"Received TCP message: {message}");

					// Respond 
					SendTcpMessage(peer, $"TCP_ECHO: {message}");
				}
			}
			catch (SocketException e)
			{
				// Handle disconnection
				if (e.SocketErrorCode == SocketError.ConnectionReset || e.SocketErrorCode == SocketError.NotConnected)
				{
					GD.Print("TCP Client disconnected.");
					_tcpPeers.Remove(peer);
				}
				else
				{
					GD.PrintErr($"TCP Receive error: {e.Message}");
				}
			}
		}

		// Process UDP Packets
		// simple nonblocking check
		if (_udpServer != null && _udpServer.Available > 0)
		{
			IPEndPoint remoteEP = null;

			byte[] dataBytes = _udpServer.Receive(ref remoteEP);
			string message = Encoding.UTF8.GetString(dataBytes);

			GD.Print($"Received UDP from {remoteEP.Address}:{remoteEP.Port}: {message}");

			// Send a reply back to the sender
			byte[] ackPacket = Encoding.UTF8.GetBytes("UDP Server ACK");
			_udpServer.Send(ackPacket, ackPacket.Length, remoteEP);
		}
	}

	private void SendTcpMessage(Socket peer, string message)
	{
		byte[] encodedData = Encoding.UTF8.GetBytes(message);
		byte[] fullPacket = new byte[4 + encodedData.Length];
		BitConverter.GetBytes((uint)encodedData.Length).CopyTo(fullPacket, 0);

		encodedData.CopyTo(fullPacket, 4);

		peer.Send(fullPacket);
	}
}
