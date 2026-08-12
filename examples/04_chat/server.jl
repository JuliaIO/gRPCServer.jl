using gRPCServer

# Include generated types
include("generated/chat/chat.jl")
using .chat

# Bidirectional streaming handler - receives and sends multiple messages
function chat_handler(ctx::ServerContext, stream::BidiStream{ChatMessage, ChatMessage})
    @info "Chat session started" request_id=ctx.request_id

    for message in stream
        if ctx.cancelled
            @warn "Chat cancelled by client"
            break
        end

        @info "Received message" user=message.user text=message.text

        # Echo back with server prefix
        response = ChatMessage("Server", "You said: $(message.text)")
        send!(stream, response)
    end

    close!(stream)
    @info "Chat session ended" request_id=ctx.request_id
    return nothing
end

# Service definition
struct ChatService end

function gRPCServer.service_descriptor(::ChatService)
    ServiceDescriptor(
        "chat.Chat",
        Dict(
            "Chat" => MethodDescriptor(
                "Chat", MethodType.BIDI_STREAMING,
                ChatMessage, ChatMessage,
                chat_handler
            )
        ),
        nothing
    )
end

# Run server
function main()
    host = "127.0.0.1"
    port = 50054
    server = GRPCServer(host, port;
        enable_health_check = true,
        enable_reflection = true
    )

    register!(server, ChatService())

    @info "gRPC server starting (bidirectional streaming example)" host=host port=port
    run(server)
end

main()
