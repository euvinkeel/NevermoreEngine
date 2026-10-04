-- https://zap.redblox.dev/intro/getting-started.html
-- https://zap.redblox.dev/config/types.html
opt client_output = "src/client/zap.luau"
opt server_output = "src/server/zap.luau"
opt typescript = true
opt tooling = true
opt tooling_show_internal_data = true
opt tooling_output = "src/shared/RemoteName.profiler.luau"

event ExtendHandshakeToServer = {
    from: Client,
    type: Reliable,
    call: ManyAsync,
}

event RequestEmergencyClear = {
    from: Client,
    type: Reliable,
    call: ManyAsync,
    data: struct {
        newEpoch: u32,
    }
}

event TEST_DoSomeChaos = {
    from: Server,
    type: Reliable,
    call: ManyAsync,
}
event TEST_BlamePlayer = {
    from: Server,
    type: Reliable,
    call: ManyAsync,
}
event TEST_GoodState = {
    from: Server,
    type: Reliable,
    call: ManyAsync,
}
event TEST_ReportCanonicalHash = {
    from: Client,
    type: Reliable,
    call: ManyAsync,
    data: struct {
        hash: u32,
        canonnumber: u32,
    }
}
event TEST_HALTSERVER = {
    from: Client,
    type: Reliable,
    call: ManyAsync,
    data: struct {
        servercanonnumber: u32,
    }
}

event ForceEmergencyClearOntoPlayer = {
    from: Server,
    type: Reliable,
    call: ManyAsync,
}

event SendAuthorIdAssignment = {
    from: Server,
    type: Reliable,
    call: ManyAsync,
    data: string.binary
}





type FanonName = string.binary(..12)

type SentDiffstepsZap = struct {
    diffsteps: unknown[],
    canonnumber: u32?,
    acknumber: u32?,
    epoch: u32,
    canondiffstephash: u32?,
    canonworldhash: u32?,
}

type ActionHeaderZap = struct {
    actionId: u32,
    actionArgs: unknown,
    createdNames: string.binary[],
}

type SentActionHeaders = struct {
    actionHeaders: unknown[],
    acknumber: u32?,
}

event ServerSendDiffsteps = {
    from: Server,
    type: Reliable,
    call: ManyAsync,
    data: SentDiffstepsZap,
}

event ClientSendActionHeaders = {
    from: Client,
    type: Reliable,
    call: ManyAsync,
    data: SentActionHeaders,
}

event ServerSendActionHeaders = {
    from: Server,
    type: Reliable,
    call: ManyAsync,
    data: struct {
        actionHeaders: unknown[],
    },
}

event ServerTriggerFeedback = {
    from: Server,
    type: Reliable,
    call: ManyAsync,
}

event ClientSendFeedback = {
    from: Client,
    type: Reliable,
    call: ManyAsync,
    data: struct {
        missing: string.utf8,
        bugs: string.utf8,
    },
}






event SendUncompressedDiff = {
    from: Server,
    type: Reliable,
    call: ManyAsync,
    data: unknown,
}

event ServerSendUncompressedPackage = {
    from: Server,
    type: Reliable,
    call: ManyAsync,
    data: unknown,
}

event ClientSendUncompressedPackage = {
    from: Client,
    type: Reliable,
    call: ManyAsync,
    data: unknown,
}

event UpdateClientHash = {
    from: Client,
    type: Reliable,
    call: ManyAsync,
    data: unknown,
}


event ServerStreamUPosition = {
    from: Server,
    type: Unreliable,
    call: ManyAsync,
    data: struct {
        fanon_name: FanonName,
        position: Vector3
    },
}
event ServerStreamUVelocity = {
    from: Server,
    type: Unreliable,
    call: ManyAsync,
    data: struct {
        fanon_name: FanonName,
        velocity: Vector3
    },
}
event ServerStreamUDirection = {
    from: Server,
    type: Unreliable,
    call: ManyAsync,
    data: struct {
        fanon_name: FanonName,
        direction: Vector3
    },
}

event ClientStreamUPosition = {
    from: Client,
    type: Unreliable,
    call: ManyAsync,
    data: struct {
        fanon_name: FanonName,
        position: Vector3
    },
}
event ClientStreamUVelocity = {
    from: Client,
    type: Unreliable,
    call: ManyAsync,
    data: struct {
        fanon_name: FanonName,
        velocity: Vector3
    },
}
event ClientStreamUDirection = {
    from: Client,
    type: Unreliable,
    call: ManyAsync,
    data: struct {
        fanon_name: FanonName,
        direction: Vector3
    },
}

event SendNotificationToClient = {
    from: Server,
    type: Reliable,
    call: ManyAsync,
    data: struct {
        message: string.utf8,
        color: Color3?,
    }
}

event SendLevelupToClient = {
    from: Server,
    type: Reliable,
    call: ManyAsync,
    data: struct {
        level: i32,
    }
}


event AcknowledgeHandshakeNewSID = {
    from: Server,
    type: Reliable,
    call: ManyAsync,
    data: i32
}

event DevDumpServer = {
    from: Server,
    type: Reliable,
    call: ManyAsync,
    data: string.utf8
}

event DevDumpClientCatchupRequest = {
    from: Client,
    type: Reliable,
    call: ManyAsync
}

event DevDumpClient = {
    from: Client,
    type: Reliable,
    call: ManyAsync,
    data: string.utf8
}