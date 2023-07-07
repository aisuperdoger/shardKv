g++ server.cpp -lzmq -pthread -o server
g++ client.cpp -lzmq -pthread -o client

cd shardmaster
g++ server.cpp -lzmq -pthread -o masterServer
g++ client.cpp -lzmq -pthread -o masterClient