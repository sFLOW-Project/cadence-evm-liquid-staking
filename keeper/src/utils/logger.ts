import winston from 'winston'

import { getEnv } from '../config'

const runtimeEnv = getEnv()

function stringifyLogValue(value: unknown): string {
  if (typeof value === 'string') {
    return value
  }

  if (
    typeof value === 'number' ||
    typeof value === 'boolean' ||
    typeof value === 'bigint'
  ) {
    return String(value)
  }

  if (value == null) {
    return ''
  }

  return JSON.stringify(value, (key, nestedValue) =>
    typeof nestedValue === 'bigint' ? nestedValue.toString() : nestedValue
  )
}

// Custom log format for production (JSON)
const jsonFormat = winston.format.combine(
  winston.format.timestamp(),
  winston.format.printf((info) => {
    return JSON.stringify(info, (key, value) =>
      typeof value === 'bigint' ? value.toString() : value
    )
  })
)

// Console format for development
const consoleFormat = winston.format.combine(
  winston.format.colorize(),
  winston.format.timestamp({
    format: 'YYYY-MM-DD HH:mm:ss',
  }),
  winston.format.printf(({ timestamp, level, message, ...meta }) => {
    const metaStr = Object.keys(meta).length
      ? JSON.stringify(meta, null, 2)
      : ''
    return `${stringifyLogValue(timestamp)} [${stringifyLogValue(level)}]: ${stringifyLogValue(message)}${metaStr ? ` ${metaStr}` : ''}`
  })
)

// Create the logger instance
export const logger = winston.createLogger({
  level: runtimeEnv.logLevel,
  format: runtimeEnv.nodeEnv === 'production' ? jsonFormat : consoleFormat,
  defaultMeta: { service: 'ethereum-indexer' },
  transports: [
    new winston.transports.Console({
      format: consoleFormat,
    }),

    // Write to files in production
    ...(runtimeEnv.nodeEnv === 'production'
      ? [
          new winston.transports.File({
            filename: 'logs/error.log',
            level: 'error',
            format: jsonFormat,
          }),
          new winston.transports.File({
            filename: 'logs/combined.log',
            format: jsonFormat,
          }),
        ]
      : []),
  ],
})

// Helper functions for common logging patterns
export const loggerHelpers = {
  logError: (
    operation: string,
    error: Error | string,
    context?: Record<string, any>
  ) => {
    logger.error(`Error in ${operation}`, {
      // message: error instanceof Error ? error.message : "",
      ...context,
    })
  },

  logStartup: (config: Record<string, any>) => {
    logger.info('Indexer starting up', {
      config: {
        ...config,
        // Don't log sensitive information
        rpcUrl: config.rpcUrl ? '[REDACTED]' : undefined,
        rabbitmqUrl: config.rabbitmq?.url ? '[REDACTED]' : undefined,
      },
      timestamp: Date.now(),
    })
  },
}
