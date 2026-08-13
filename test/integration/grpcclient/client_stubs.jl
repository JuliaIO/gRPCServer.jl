# Manual gRPCClient service client constructors for InteropTestService
# These mirror what ProtoBuf.jl codegen would produce with gRPCClient loaded

using gRPCClient: gRPCServiceClient, grpc_global_handle

# Unary: Echo
InteropTestService_Echo_Client(host, port; kwargs...) =
    gRPCServiceClient{InteropRequest, false, InteropResponse, false}(
        host, port, "/interop.InteropTestService/Echo"; kwargs...
    )

# Unary: Fail (returns gRPC error based on request id)
InteropTestService_Fail_Client(host, port; kwargs...) =
    gRPCServiceClient{InteropRequest, false, InteropResponse, false}(
        host, port, "/interop.InteropTestService/Fail"; kwargs...
    )

# Server Streaming: StreamResponses
    InteropTestService_StreamResponses_Client(host, port; kwargs...) =
        gRPCServiceClient{InteropRequest, false, InteropResponse, true}(
            host, port, "/interop.InteropTestService/StreamResponses"; kwargs...
        )

    # Client Streaming: CollectRequests
    InteropTestService_CollectRequests_Client(host, port; kwargs...) =
        gRPCServiceClient{InteropRequest, true, InteropResponse, false}(
            host, port, "/interop.InteropTestService/CollectRequests"; kwargs...
        )

    InteropTestService_BiDiExchange_Client(host, port; kwargs...) =
        gRPCServiceClient{InteropRequest, true, InteropResponse, true}(
            host, port, "/interop.InteropTestService/BiDiExchange"; kwargs...
        )
